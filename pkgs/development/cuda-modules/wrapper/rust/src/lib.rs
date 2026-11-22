//! Linux process, argument, and artifact handling for CUDA tool wrappers.

pub mod arguments;
pub mod artifact;
pub mod files;
pub mod path_prefix_map;
pub mod process;
pub mod ptx;
pub mod scratch;

fn space(byte: u8) -> bool {
    matches!(byte, b' ' | b'\t' | b'\r' | b'\n' | 0x0b | 0x0c)
}

fn push_quoted(text: &mut Vec<u8>, contents: &[u8]) {
    text.push(b'"');
    for &byte in contents {
        if matches!(byte, b'\\' | b'"') {
            text.push(b'\\');
        }
        text.push(byte);
    }
    text.push(b'"');
}

#[cfg(test)]
mod tests;
