use std::fs;
use std::io::{self, Read};
use std::ops::ControlFlow::{Break, Continue};
use std::os::unix::fs::FileExt;
use tool_wrapper::process::Tool;

use crate::{
    arguments::{Kind, Operands, informational, operand_file, rewrite_options_until},
    path_prefix_map::PathPrefixMap,
    ptx::{normalize_source_info, rewritten_input},
};

pub fn ptxas(tool: Tool) -> io::Result<i32> {
    let paths = PathPrefixMap::from_environment()?;
    let (operands, options) = operand_file(&tool)?;
    let mut timestamps = false;
    for option in options {
        timestamps = match option.as_slice() {
            b"--ptxas-inherits-mtime=true" => true,
            b"--ptxas-inherits-mtime=false" => false,
            _ => return Err(io::Error::other("invalid ptxas launcher option")),
        };
    }
    if !timestamps && paths.is_empty() {
        return Ok(tool.forward());
    }
    let table = fs::read(operands)?;
    let operands = Operands::new(&tool, &table);
    let mut stdin = None;
    let mut input_error = None;
    let rewritten = rewrite_options_until(
        &tool.args,
        |name, next| operands.classify(name, next),
        |arg, files| {
            if informational(arg.name)
                || matches!(
                    arg.name,
                    b"-arch-ls" | b"--list-arch" | b"-version-ls" | b"--list-version"
                )
            {
                input_error = None;
                return Ok(Break(()));
            }
            if matches!(arg.name, b"-ias" | b"--input-as-string") {
                return Ok(Continue(normalize_source_info(
                    arg.value, &paths, timestamps,
                )?));
            }
            if arg.value == b"-" && arg.kind == Kind::Plain {
                // Defer reading until we know the operation consumes input.
                let (path, file) = files.reserve(c"cuda-ptx-stdin")?;
                stdin.get_or_insert(file);
                return Ok(Continue(Some(path)));
            }
            if arg.kind == Kind::Plain && !arg.value.starts_with(b"-") {
                match rewritten_input(files, arg.value, &paths, timestamps) {
                    Ok(replacement) => return Ok(Continue(replacement)),
                    Err(error) => {
                        // A later informational flag can make input files irrelevant.
                        input_error.get_or_insert(error);
                    }
                }
            }
            Ok(Continue(None))
        },
    )?;
    if let Some(error) = input_error {
        return Err(error);
    }
    if rewritten.is_some()
        && let Some(file) = stdin
    {
        let mut input = Vec::new();
        io::stdin().read_to_end(&mut input)?;
        let mapped = normalize_source_info(&input, &paths, timestamps)?;
        file.write_all_at(mapped.as_deref().unwrap_or(&input), 0)?;
    }
    Ok(tool.with_prepared_args(rewritten).forward())
}
