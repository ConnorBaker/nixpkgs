//! CUDA executable adapters and PTX normalization.

#[cfg(feature = "wrapper")]
pub mod adapters;
#[cfg(feature = "wrapper")]
pub mod arguments;
pub mod artifact;
pub mod ptx;

pub use tool_wrapper::path_prefix_map;
#[cfg(feature = "wrapper")]
pub use tool_wrapper::{files, process, scratch, wrap_tool};

fn space(byte: u8) -> bool {
    matches!(byte, b' ' | b'\t' | b'\r' | b'\n' | 0x0b | 0x0c)
}

#[cfg(test)]
mod tests;
