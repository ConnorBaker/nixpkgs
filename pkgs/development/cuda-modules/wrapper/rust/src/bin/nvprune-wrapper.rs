use cuda_tool_wrapper::{
    arguments::{classify, last_output},
    artifact::normalize_archive_metadata,
    files::special_file,
    process::wrapper_main,
};
use std::process::ExitCode;

const OPERANDS: &[&[u8]] = &[
    b"-o",
    b"--output-file",
    b"-arch",
    b"--arch",
    b"-gencode",
    b"--generate-code",
];

fn main() -> ExitCode {
    wrapper_main("nvprune", |tool| {
        let command = tool.command(&tool.args);
        if let Ok(Some(path)) = last_output(&tool.args, |name| classify(name, OPERANDS))
            && !special_file(&path)
        {
            return tool.edit_output(command, path, normalize_archive_metadata);
        }
        Ok(tool.exec(command))
    })
}
