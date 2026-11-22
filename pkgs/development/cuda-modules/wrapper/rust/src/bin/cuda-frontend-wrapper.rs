use cuda_tool_wrapper::{
    arguments::{Kind, rewrite_options},
    path_prefix_map::PathPrefixMap,
    process::installed_wrapper_main,
};
use std::process::ExitCode;

fn main() -> ExitCode {
    installed_wrapper_main(|tool| {
        let paths = PathPrefixMap::from_environment()?;
        let rewritten = if paths.is_empty() {
            None
        } else {
            rewrite_options(
                &tool.args,
                |name| {
                    if name == b"--orig_src_path_name" {
                        Kind::Operand
                    } else {
                        Kind::Plain
                    }
                },
                |arg, _| {
                    Ok((arg.kind == Kind::Operand)
                        .then(|| paths.remap(arg.value))
                        .flatten())
                },
            )?
        };
        Ok(tool.exec_rewritten(rewritten))
    })
}
