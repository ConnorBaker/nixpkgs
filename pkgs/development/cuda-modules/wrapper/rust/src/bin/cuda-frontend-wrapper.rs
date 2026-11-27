use cuda_tool_wrapper::{adapters::frontend, wrap_tool};
use std::process::ExitCode;

fn main() -> ExitCode {
    wrap_tool!(None, frontend)
}
