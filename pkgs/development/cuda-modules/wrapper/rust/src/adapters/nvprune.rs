use crate::{arguments::last_output, artifact::normalize_archive_metadata};
use std::io;
use std::path::Path;
use tool_wrapper::process::Tool;

pub fn nvprune(tool: Tool) -> io::Result<i32> {
    let command = tool.command(&tool.args);
    if let Some(path) = last_output(&tool.args, &[])?
        && path != Path::new("/dev/null")
    {
        return tool.edit_output(command, path, normalize_archive_metadata);
    }
    Ok(tool.exec(command))
}
