#[rustfmt::skip]
const OPERANDS: &[&[u8]] = &[
    b"-o", b"--output-file", b"-arch", b"--gpu-name", b"-O", b"--opt-level", b"-m", b"--machine",
    b"-e", b"--entry", b"-ias", b"--input-as-string", b"-Ofc", b"--Ofast-compile",
    b"-dlcm", b"--def-load-cache", b"-dscm", b"--def-store-cache", b"-flcm", b"--force-load-cache",
    b"-fmad", b"--fmad", b"-func-maxrregcount", b"--device-function-maxrregcount", b"-maxntid", b"--maxntid",
    b"-maxrregcount", b"--maxrregcount", b"-minnctapersm", b"--minnctapersm", b"-pic", b"--position-independent-code",
    b"-regUsageLevel", b"--register-usage-level", b"-split-compile", b"--split-compile",
    b"-allow-expensive-optimizations", b"--allow-expensive-optimizations",
    b"-device-stack-protector", b"--device-stack-protector", b"-apply-controls", b"--apply-controls",
    b"-enable-func-clone-sc", b"--enable-func-clone-sc", b"-sanitize", b"--sanitize", b"--nv-host",
];

use cuda_tool_wrapper::{
    arguments::{Kind, RewriteError, classify, informational, rewrite_options},
    process::wrapper_main,
    ptx::{PathPrefixMap, normalize_source_info, rewritten_input},
};
use std::process::ExitCode;

fn main() -> ExitCode {
    wrapper_main("ptxas", |tool| {
        let paths = PathPrefixMap::from_environment()?;
        let timestamps = option_env!("PTXAS_INHERITS_MTIME") == Some("true");
        if !timestamps && paths.is_empty() {
            return Ok(tool.exec(tool.command(&tool.args)));
        }
        let mut query = false;
        let rewritten = rewrite_options(
            &tool.args,
            |name| classify(name, OPERANDS),
            |name, kind, value, files| {
                query |= informational(name);
                if query {
                    return Ok(None);
                }
                if matches!(name, b"-ias" | b"--input-as-string") {
                    return Ok(normalize_source_info(value, &paths, timestamps));
                }
                if kind == Kind::Plain && !value.starts_with(b"-") {
                    return Ok(rewritten_input(value, &paths, timestamps)?.map(|fd| files.add(fd)));
                }
                Ok(None)
            },
        );
        match rewritten {
            Ok(Some((args, _files))) if !query => Ok(tool.exec(tool.command(&args))),
            Err(RewriteError::Input(error)) => Err(error),
            _ => Ok(tool.exec(tool.command(&tool.args))),
        }
    })
}
