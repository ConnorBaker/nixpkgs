#[cfg(feature = "wrapper")]
use crate::files::{InputFiles, read_regular};
use crate::path_prefix_map::PathPrefixMap;
use crate::space;
use std::io;
#[cfg(feature = "wrapper")]
use std::{ffi::OsStr, os::unix::ffi::OsStrExt};
use tool_wrapper::ByteEdits;

fn integer_literal(value: &[u8]) -> Option<u64> {
    let (digits, radix) = match value.strip_suffix(b"U").unwrap_or(value) {
        [b'0', b'x' | b'X', digits @ ..] => (digits, 16),
        [b'0', b'b' | b'B', digits @ ..] => (digits, 2),
        digits @ [b'0', ..] => (digits, 8),
        digits => (digits, 10),
    };
    if !digits.first().is_some_and(u8::is_ascii_hexdigit) {
        return None;
    }
    u64::from_str_radix(std::str::from_utf8(digits).ok()?, radix).ok()
}

fn identifier(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || b"._$%".contains(&byte)
}

fn token<'a>(input: &mut &'a [u8]) -> &'a [u8] {
    loop {
        let size = input.len();
        match *input {
            [] => return b"",
            [b'/', b'/', ..] => {
                let end = memchr::memchr(b'\n', input).unwrap_or(size);
                *input = &input[end..];
            }
            [b'/', b'*', tail @ ..] => {
                let end = memchr::memmem::find(tail, b"*/");
                *input = &input[end.map_or(size, |index| index + 4)..];
            }
            [byte, tail @ ..] if space(*byte) => *input = tail,
            _ => break,
        }
    }
    let size = if input[0] == b'"' {
        // PTX retains backslashes in quoted filenames, including before a closing quote.
        let Some(index) = memchr::memchr(b'"', &input[1..]) else {
            *input = b"";
            return b"";
        };
        index + 2
    } else if identifier(input[0]) {
        input.iter().take_while(|&&byte| identifier(byte)).count()
    } else {
        1
    };
    let (word, rest) = input.split_at(size);
    *input = rest;
    word
}

pub fn normalize_source_info(
    ptx: &[u8],
    paths: &PathPrefixMap,
    normalize_timestamp: bool,
) -> io::Result<Option<Vec<u8>>> {
    let mut input = ptx;
    if token(&mut input) != b".version" {
        return Ok(None);
    }
    let mut edits = ByteEdits::new(ptx);
    while !input.is_empty() {
        if token(&mut input) != b".file" {
            continue;
        }
        let index = token(&mut input);
        let spelling = token(&mut input);
        let [b'"', path @ .., b'"'] = spelling else {
            continue;
        };
        if integer_literal(index).is_none() {
            continue;
        }

        let mapped = paths.remap(path);
        let mut following = input;
        let add_timestamp = normalize_timestamp && token(&mut following) != b",";
        let mut timestamp = None;
        if normalize_timestamp && !add_timestamp {
            let value = token(&mut following);
            if integer_literal(value) == Some(0) && token(&mut following) == b"," {
                timestamp = ptx.subslice_range(value);
            }
        }
        if mapped.is_none() && !add_timestamp && timestamp.is_none() {
            continue;
        }
        let filename = ptx
            .subslice_range(spelling)
            .expect("filename from the PTX input");
        let end = filename.end;
        if let Some(mapped) = mapped {
            if mapped.contains(&b'"') {
                return Err(io::Error::other(
                    "cannot represent a double quote in a PTX filename",
                ));
            }
            edits.replace(filename.start + 1..end - 1, &mapped);
        }
        // A nonzero timestamp tells ptxas to use both fields as written.
        if add_timestamp {
            edits.replace(end..end, b", 1, 0");
        }
        if let Some(timestamp) = timestamp {
            edits.replace(timestamp, b"1");
        }
    }
    Ok(edits.finish())
}

#[cfg(feature = "wrapper")]
pub fn rewritten_input(
    files: &mut InputFiles,
    path: &[u8],
    paths: &PathPrefixMap,
    normalize_timestamp: bool,
) -> io::Result<Option<Vec<u8>>> {
    let mut remaining = usize::MAX;
    let contents = read_regular(OsStr::from_bytes(path), &mut remaining)?;
    normalize_source_info(&contents, paths, normalize_timestamp)?
        .map(|contents| files.stage(c"cuda-ptx-input", &contents))
        .transpose()
}
