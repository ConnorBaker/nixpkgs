use cuda_tool_wrapper::{
    arguments::{Kind, rewrite_options},
    files::same_file,
    path_prefix_map::PathPrefixMap,
    process::installed_wrapper_main,
};
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::path::PathBuf;
use std::process::ExitCode;
use std::{env, ffi::OsString, fs};

// cicc uses PWD for debug and LTO metadata when it names the current directory.
fn mapped_working_directory(paths: &PathPrefixMap) -> Option<PathBuf> {
    let cwd = env::current_dir().ok()?;
    let mapped = PathBuf::from(OsString::from_vec(paths.remap(cwd.as_os_str().as_bytes())?));
    if !mapped.is_absolute() {
        return None;
    }
    let current = fs::metadata(".").ok()?;
    let alias = fs::metadata(&mapped).ok()?;
    same_file(&current, &alias).then_some(mapped)
}

fn main() -> ExitCode {
    installed_wrapper_main(|tool| {
        let paths = PathPrefixMap::from_environment()?;
        if paths.is_empty() {
            return Ok(tool.exec_rewritten(None));
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
        let args = rewritten.as_ref().map_or(&tool.args, |result| &result.args);
        let mut command = tool.command(args);
        if tool.name() == "cicc"
            && let Some(path) = mapped_working_directory(&paths)
        {
            command.env("PWD", path);
        }
        Ok(tool.exec(command))
    })
}
