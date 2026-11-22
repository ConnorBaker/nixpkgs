use crate::files::{anonymous_input, read_regular};
use crate::path_prefix_map::PathPrefixMap;
use crate::{push_quoted, space};
use std::ffi::OsStr;
use std::fs::File;
use std::io;
use std::os::unix::ffi::OsStrExt;

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
                let end = input.iter().position(|&byte| byte == b'\n').unwrap_or(size);
                *input = &input[end..];
            }
            [b'/', b'*', tail @ ..] => {
                let end = tail.windows(2).position(|part| part == b"*/");
                *input = &input[end.map_or(size, |index| index + 4)..];
            }
            [byte, tail @ ..] if space(*byte) => *input = tail,
            _ => break,
        }
    }
    let size = if input[0] == b'"' {
        let mut escaped = false;
        let end = input[1..].iter().position(|&byte| {
            let close = !escaped && byte == b'"';
            escaped = !escaped && byte == b'\\';
            close
        });
        let Some(index) = end else {
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
) -> Option<Vec<u8>> {
    let mut input = ptx;
    if token(&mut input) != b".version" {
        return None;
    }
    let mut result = Vec::new();
    let mut copied = 0;
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

        let filename_end = ptx.len() - input.len();
        let mapped = (!path.contains(&b'\\'))
            .then(|| paths.remap(path))
            .flatten();
        let mut following = input;
        let add_timestamp = normalize_timestamp && token(&mut following) != b",";
        let mut timestamp = None;
        if normalize_timestamp && !add_timestamp {
            let value = token(&mut following);
            let end = ptx.len() - following.len();
            if integer_literal(value) == Some(0) && token(&mut following) == b"," {
                timestamp = Some(end - value.len()..end);
            }
        }
        if mapped.is_none() && !add_timestamp && timestamp.is_none() {
            continue;
        }
        result.extend_from_slice(&ptx[copied..filename_end - spelling.len()]);
        if let Some(mapped) = mapped {
            push_quoted(&mut result, &mapped);
        } else {
            result.extend_from_slice(spelling);
        }
        copied = filename_end;
        // A nonzero timestamp tells ptxas to use both fields as written.
        if add_timestamp {
            result.extend_from_slice(b", 1, 0");
        }
        if let Some(timestamp) = timestamp {
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
