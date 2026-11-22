//! Linux process, argument, and artifact handling for CUDA tool wrappers.

pub mod arguments;
pub mod artifact;
pub mod files;
pub mod process;
pub mod ptx;
pub mod scratch;

pub fn space(byte: u8) -> bool {
    matches!(byte, b' ' | b'\t' | b'\r' | b'\n' | 0x0b | 0x0c)
}

#[cfg(test)]
mod tests;
