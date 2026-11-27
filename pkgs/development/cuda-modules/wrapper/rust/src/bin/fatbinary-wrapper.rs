use cuda_tool_wrapper::{adapters::fatbinary, wrap_tool};
use std::process::ExitCode;

fn main() -> ExitCode {
    wrap_tool!(Some("fatbinary"), fatbinary)
}
