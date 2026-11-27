use cuda_tool_wrapper::{adapters, wrap_tool};
use std::io;
use std::os::unix::ffi::OsStrExt;
use std::process::ExitCode;

fn main() -> ExitCode {
    wrap_tool!(launcher => |tool| {
        let name = tool.name().as_bytes();
        if !tool.launcher_options().is_empty() && !matches!(name, b"nvcc" | b"ptxas") {
            return Err(io::Error::other("launcher options are supported by nvcc and ptxas"));
        }
        match name {
            b"cudafe++" | b"cicc" => adapters::frontend(tool),
            b"fatbinary" => adapters::fatbinary(tool),
            b"nvcc" => adapters::nvcc(tool),
            b"nvlink" => adapters::nvlink(tool),
            b"nvprune" => adapters::nvprune(tool),
            b"ptxas" => adapters::ptxas(tool),
            _ => Err(io::Error::other("unknown CUDA launcher name")),
        }
    })
}
