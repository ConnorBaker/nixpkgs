#![forbid(unsafe_code)]
use core::str;
const STORE: &[u8] = env!("NIX_CUDA_STORE_DIR").as_bytes();
const PREFIX: &[u8] = b"/compat/libcuda.so.";
const B32: &[u8] = b"0123456789abcdfghijklmnpqrsvwxyz";
fn number(bytes: &[u8]) -> Option<u32> {
    // u32::from_str accepts a leading '+'. The manifest grammar does not.
    bytes.first()?.is_ascii_digit().then_some(())?;
    str::from_utf8(bytes).ok()?.parse().ok()
}

pub(crate) fn version(text: &[u8], patch: bool) -> Option<[u32; 3]> {
    let mut fields = text.split(|&c| c == b'.');
    let major = number(fields.next()?)?;
    let minor = number(fields.next()?)?;
    let last = match fields.next() {
        Some(x) => number(x)?,
        None if !patch => 0,
        None => return None,
    };
    fields.next().is_none().then_some([major, minor, last])
}

pub(crate) fn output(path: &[u8]) -> Option<&[u8]> {
    let rest = path.strip_prefix(STORE)?.strip_prefix(b"/")?;
    let n = rest.iter().position(|&c| c == b'/')?;
    (n > 33 && rest[32] == b'-' && rest[..32].iter().all(|c| B32.contains(c)))
        .then(|| &path[..path.len() - (rest.len() - n)])
}

pub(crate) fn eligible<'a>(
    root: &[u8],
    body: &'a [u8],
    kernel: [u32; 3],
) -> Option<([u32; 3], &'a [u8])> {
    let mut lines = body.strip_suffix(b"\n")?.split(|&c| c == b'\n');
    let candidate = version(lines.next()?, true)?;
    let branches = lines.next()?;
    let path = lines.next()?;
    if lines.next().is_some() || candidate <= kernel || path.len() >= super::PATH_MAX {
        return None;
    }
    let suffix = path.strip_prefix(root)?.strip_prefix(PREFIX)?;
    if version(suffix, false)? != candidate {
        return None;
    }
    // Validate the whole list even after finding a supported branch.
    let accepted = branches
        .split(|&c| c == b' ')
        .try_fold(false, |seen, x| Some(seen | (number(x)? == kernel[0])))?;
    accepted.then_some((candidate, path))
}
