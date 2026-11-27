use cuda_tool_wrapper::{adapters::nvprune, wrap_tool};
use std::process::ExitCode;

fn main() -> ExitCode {
    wrap_tool!(Some("nvprune"), nvprune)
}
