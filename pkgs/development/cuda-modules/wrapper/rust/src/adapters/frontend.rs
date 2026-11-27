use crate::{
    arguments::{Kind, rewrite_options},
    files::mapped_working_directory,
    path_prefix_map::PathPrefixMap,
};
use std::io;
use tool_wrapper::process::Tool;

pub fn frontend(tool: Tool) -> io::Result<i32> {
    let paths = PathPrefixMap::from_environment()?;
    if paths.is_empty() {
        return Ok(tool.forward());
    }
    let rewritten = rewrite_options(
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
    )?;
    let tool = tool.with_prepared_args(rewritten);
    let mut command = tool.command(&tool.args);
    // cicc uses PWD for debug and LTO metadata when it names the current directory.
    if tool.name() == "cicc"
        && let Some(path) = mapped_working_directory(&paths)
    {
        command.env("PWD", path);
    }
    Ok(tool.exec(command))
}
