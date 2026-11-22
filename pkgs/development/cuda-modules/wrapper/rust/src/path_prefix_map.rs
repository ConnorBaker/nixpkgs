use std::env;
use std::io;
use std::os::unix::ffi::OsStrExt;

#[derive(Default)]
pub struct PathPrefixMap(Vec<(Vec<u8>, Vec<u8>)>);

impl PathPrefixMap {
    pub fn from_environment() -> io::Result<Self> {
        Self::parse(
            env::var_os("BUILD_PATH_PREFIX_MAP")
                .as_deref()
                .unwrap_or_default()
                .as_bytes(),
        )
    }

    pub fn parse(encoded: &[u8]) -> io::Result<Self> {
        let invalid = || io::Error::other("invalid BUILD_PATH_PREFIX_MAP");
        let mut prefixes = Vec::new();
        for entry in encoded.split(|&b| b == b':').filter(|s| !s.is_empty()) {
            let mut fields = entry.split(|&b| b == b'=');
            let (Some(target), Some(source), None) = (fields.next(), fields.next(), fields.next())
            else {
                return Err(invalid());
            };
            prefixes.push((
                decode(target).ok_or_else(invalid)?,
                decode(source).ok_or_else(invalid)?,
            ));
        }
        Ok(Self(prefixes))
    }

    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }

    pub fn remap(&self, path: &[u8]) -> Option<Vec<u8>> {
        for (target, source) in self.0.iter().rev() {
            if let Some(suffix) = path.strip_prefix(source.as_slice())
                && (source.is_empty()
                    || source.ends_with(b"/")
                    || suffix.is_empty()
                    || suffix.starts_with(b"/"))
            {
                return Some([target.as_slice(), suffix].concat());
            }
        }
        None
    }
}

fn decode(encoded: &[u8]) -> Option<Vec<u8>> {
    let mut decoded = Vec::new();
    let mut input = encoded.iter().copied();
    while let Some(byte) = input.next() {
        decoded.push(match byte {
            b'%' => match input.next()? {
                b'#' => b'%',
                b'+' => b'=',
                b'.' => b':',
                _ => return None,
            },
            byte => byte,
        });
    }
    Some(decoded)
}
