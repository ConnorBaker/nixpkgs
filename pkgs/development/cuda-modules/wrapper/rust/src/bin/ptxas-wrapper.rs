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
    arguments::{Kind, classify, informational, rewrite_options},
    path_prefix_map::PathPrefixMap,
    process::wrapper_main,
    ptx::{normalize_source_info, rewritten_input},
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
            |arg, files| {
                query |= informational(arg.name);
                if query {
                    return Ok(None);
                }
                if matches!(arg.name, b"-ias" | b"--input-as-string") {
                    return Ok(normalize_source_info(arg.value, &paths, timestamps));
                }
                if arg.kind == Kind::Plain && !arg.value.starts_with(b"-") {
                    return Ok(
                        rewritten_input(arg.value, &paths, timestamps)?.map(|fd| files.add(fd))
                    );
                }
                Ok(None)
            },
        )?;
        Ok(tool.exec_rewritten(rewritten.filter(|_| !query)))
    })
}
