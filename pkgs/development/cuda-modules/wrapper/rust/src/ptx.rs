use crate::files::{anonymous_input, read_regular};
use crate::space;
use std::env;
use std::ffi::OsStr;
use std::fs::File;
use std::io;
use std::ops::Range;
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

fn integer_literal(value: &[u8]) -> Option<u64> {
    let value = value.strip_suffix(b"U").unwrap_or(value);
    let (radix, digits) = if let Some(digits) = value
        .strip_prefix(b"0x")
        .or_else(|| value.strip_prefix(b"0X"))
    {
        (16, digits)
    } else if let Some(digits) = value
        .strip_prefix(b"0b")
        .or_else(|| value.strip_prefix(b"0B"))
    {
        (2, digits)
    } else if value.starts_with(b"0") {
        (8, value)
    } else {
        (10, value)
    };
    if !digits.first().is_some_and(u8::is_ascii_hexdigit) {
        return None;
    }
    u64::from_str_radix(std::str::from_utf8(digits).ok()?, radix).ok()
}

fn identifier(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || b"._$%".contains(&byte)
}

// Return token offsets so replacements can preserve all unrelated bytes.
fn token(bytes: &[u8], cursor: &mut usize) -> Option<Range<usize>> {
    loop {
        let input = bytes.get(*cursor..)?;
        let &byte = input.first()?;
        if space(byte) {
            *cursor += 1;
        } else if input.starts_with(b"//") {
            *cursor += input
                .iter()
                .position(|&b| b == b'\n')
                .unwrap_or(input.len());
        } else if input.starts_with(b"/*") {
            *cursor += input[2..]
                .windows(2)
                .position(|pair| pair == b"*/")
                .map_or(input.len(), |index| index + 4);
        } else {
            let start = *cursor;
            *cursor += 1;
            if byte == b'"' {
                while let Some(&byte) = bytes.get(*cursor) {
                    *cursor += 1;
                    if byte == b'"' {
                        break;
                    }
                    if byte == b'\\' && *cursor < bytes.len() {
                        *cursor += 1;
                    }
                }
            } else if identifier(byte) {
                while bytes.get(*cursor).is_some_and(|&b| identifier(b)) {
                    *cursor += 1;
                }
            }
            return Some(start..*cursor);
        }
    }
}

pub fn normalize_source_info(
    ptx: &[u8],
    paths: &PathPrefixMap,
    normalize_timestamp: bool,
) -> Option<Vec<u8>> {
    let mut cursor = 0;
    if &ptx[token(ptx, &mut cursor)?] != b".version" {
        return None;
    }
    let mut result = Vec::new();
    let mut copied = 0;
    while let Some(current) = token(ptx, &mut cursor) {
        if &ptx[current] != b".file" {
            continue;
        }
        let Some(index) = token(ptx, &mut cursor) else {
            break;
        };
        let Some(filename) = token(ptx, &mut cursor) else {
            break;
        };
        let spelling = &ptx[filename.clone()];
        let Some(path) = spelling
            .strip_prefix(b"\"")
            .and_then(|s| s.strip_suffix(b"\""))
        else {
            continue;
        };
        if integer_literal(&ptx[index]).is_none() {
            continue;
        }
        let mut following = cursor;
        let metadata = token(ptx, &mut following).is_some_and(|range| &ptx[range] == b",");
        let add_timestamp = normalize_timestamp && !metadata;
        let replace_timestamp = if normalize_timestamp && metadata {
            token(ptx, &mut following).filter(|range| {
                integer_literal(&ptx[range.clone()]) == Some(0)
                    && token(ptx, &mut following).is_some_and(|range| &ptx[range] == b",")
            })
        } else {
            None
        };
        let mapped = if path.contains(&b'\\') {
            None
        } else {
            paths.remap(path)
        };
        if !add_timestamp && replace_timestamp.is_none() && mapped.is_none() {
            continue;
        }
        result.extend_from_slice(&ptx[copied..filename.start]);
        if let Some(mapped) = mapped {
            result.push(b'"');
            for byte in mapped {
                if matches!(byte, b'"' | b'\\') {
                    result.push(b'\\');
                }
                result.push(byte);
            }
            result.push(b'"');
        } else {
            result.extend_from_slice(spelling);
        }
        // A nonzero timestamp tells ptxas to use both fields as written.
        if add_timestamp {
            result.extend_from_slice(b", 1, 0");
        }
        copied = filename.end;
        if let Some(timestamp) = replace_timestamp {
            result.extend_from_slice(&ptx[copied..timestamp.start]);
            result.push(b'1');
            copied = timestamp.end;
        }
    }
    if copied == 0 {
        return None;
    }
    result.extend_from_slice(&ptx[copied..]);
    Some(result)
}

pub fn rewritten_input(
    path: &[u8],
    paths: &PathPrefixMap,
    normalize_timestamp: bool,
) -> io::Result<Option<File>> {
    let mut remaining = usize::MAX;
    let Ok(contents) = read_regular(OsStr::from_bytes(path), &mut remaining) else {
        return Ok(None);
    };
    normalize_source_info(&contents, paths, normalize_timestamp)
        .map(|bytes| anonymous_input(c"cuda-ptx-input", &bytes))
        .transpose()
}
