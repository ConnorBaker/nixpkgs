use cuda_tool_wrapper::{adapters::nvlink, wrap_tool};
use std::process::ExitCode;

fn main() -> ExitCode {
    wrap_tool!(Some("nvlink"), nvlink)
}
