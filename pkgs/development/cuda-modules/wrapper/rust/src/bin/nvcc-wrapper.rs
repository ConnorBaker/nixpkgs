#[rustfmt::skip]
const OPERANDS: &[&[u8]] = &[
    b"include", b"pre-include", b"I", b"include-path",
    b"isystem", b"system-include", b"L", b"library-path", b"l", b"library", b"D", b"define-macro",
    b"U", b"undefine-macro", b"ccbin", b"compiler-bindir", b"arbin", b"archiver-binary", b"ldir",
    b"libdevice-directory", b"apply-controls", b"MF", b"dependency-output", b"MT", b"dependency-target-name",
    b"Xcompiler", b"compiler-options", b"Xlinker", b"linker-options", b"Xarchive", b"archive-options",
    b"Xptxas", b"ptxas-options", b"Xnvlink", b"nvlink-options", b"Xnvprune", b"nvprune-options", b"Xtileiras",
    b"tileiras-options", b"time", b"fdevice-time-trace", b"run-args",
    b"create-pch", b"use-pch", b"pch-dir", b"qpp-config",
];

use cuda_tool_wrapper::{
    arguments::{Argument, Arguments, Kind, Quote, expand, split_option, tokenize},
    files::{GeneratedFile, special_file},
    process::{Tool, exit_status, wrapper_main},
    ptx::{PathPrefixMap, normalize_source_info},
    scratch::{ScratchDirectory, stable_id},
};
use std::env;
use std::ffi::{OsStr, OsString};
use std::io;
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};

fn bare_option(name: &[u8]) -> &[u8] {
    name.strip_prefix(b"--")
        .or_else(|| name.strip_prefix(b"-"))
        .unwrap_or_default()
}

fn takes_operand(name: &[u8]) -> bool {
    matches!(
        name,
        b"keep-dir"
            | b"frandom-seed"
            | b"x"
            | b"o"
            | b"output-file"
            | b"odir"
            | b"output-directory"
    ) || OPERANDS.contains(&name)
}

fn effective_arguments(args: &[Argument]) -> io::Result<Arguments> {
    let flags = |name| {
        tokenize(
            env::var_os(name).as_deref().unwrap_or_default().as_bytes(),
            Quote::Preserve,
        )
    };
    let mut effective = flags("NVCC_PREPEND_FLAGS")?;
    effective.extend_from_slice(args);
    effective.extend(flags("NVCC_APPEND_FLAGS")?);
    expand(
        &effective,
        |name| match bare_option(name) {
            b"optf" | b"options-file" => Kind::OptionsFile,
            name if takes_operand(name) => Kind::Operand,
            _ => Kind::Plain,
        },
        Quote::Preserve,
        4 * 1024 * 1024,
    )
}

struct Compilation {
    sources: Arguments,
    output: Option<PathBuf>,
    output_directory: PathBuf,
    keep: bool,
    seed: bool,
    ptx: bool,
}

impl Compilation {
    fn inspect(args: &[Argument]) -> Option<Self> {
        let mut build = Self {
            sources: Vec::new(),
            output: None,
            output_directory: PathBuf::new(),
            keep: true,
            seed: option_env!("NVCC_HAS_RANDOM_SEED") == Some("true"),
            ptx: false,
        };
        let mut explicit_language = false;
        let mut inputs = Vec::new();
        let mut args = args.iter();
        while let Some(arg) = args.next() {
            let (spelling, bound) = split_option(arg);
            let name = bare_option(spelling);
            if matches!(
                name,
                b"dryrun"
                    | b"version"
                    | b"V"
                    | b"h"
                    | b"help"
                    | b"E"
                    | b"preprocess"
                    | b"M"
                    | b"MM"
                    | b"generate-dependencies"
                    | b"generate-nonsystem-dependencies"
                    | b"clean"
                    | b"clean-targets"
            ) {
                return None;
            }
            if matches!(
                name,
                b"keep" | b"keep-dir" | b"save-temps" | b"objdir-as-tempdir" | b"objtemp"
            ) {
                build.keep = false;
            }
            build.seed &= name != b"frandom-seed";
            build.ptx |= name == b"ptx";
            if takes_operand(name) {
                let value = bound.or_else(|| args.next().map(Vec::as_slice))?;
                let path = || PathBuf::from(OsStr::from_bytes(value));
                match name {
                    b"o" | b"output-file" => build.output = Some(path()),
                    b"odir" | b"output-directory" => build.output_directory = path(),
                    b"x" => explicit_language = matches!(value, b"cu" | b"c++" | b"c"),
                    _ => {}
                }
            } else if !arg.is_empty() && !arg.starts_with(b"-") {
                inputs.push(arg);
            }
        }

        let mut stems = Vec::new();
        for input in inputs {
            let path = Path::new(OsStr::from_bytes(input));
            let extension = path.extension().unwrap_or_default().as_bytes();
            if !explicit_language
                && !matches!(
                    extension,
                    b"cu" | b"c" | b"cc" | b"cxx" | b"cpp" | b"c++" | b"C" | b"CPP"
                )
            {
                continue;
            }
            let stem = path.file_stem();
            if stems.contains(&stem) {
                build.keep = false;
            }
            stems.push(stem);
            build.sources.push(input.clone());
        }
        // NVCC accepts one seed per invocation and requires distinct seeds
        // for different translation units.
        build.seed &= build.sources.len() == 1;
        (!build.sources.is_empty()).then_some(build)
    }

    fn ptx_outputs(&self) -> io::Result<Vec<GeneratedFile>> {
        let mut paths = Vec::new();
        if let Some(output) = &self.output {
            paths.push(output.clone());
        } else {
            for source in &self.sources {
                let name = Path::new(OsStr::from_bytes(source))
                    .file_name()
                    .unwrap_or_default();
                let path = self
                    .output_directory
                    .join(Path::new(name).with_extension("ptx"));
                if !paths.contains(&path) {
                    paths.push(path);
                }
            }
        }
        paths
            .into_iter()
            .filter(|path| {
                !matches!(path.as_os_str().as_bytes(), b"-" | b"/dev/stdout") && !special_file(path)
            })
            .map(GeneratedFile::new)
            .collect()
    }
}

fn nvcc_command(tool: &Tool, args: &[Argument]) -> Command {
    let mut command = tool.profile_command(args);
    if let Some(backend) = option_env!("NVCC_BACKEND_BIN") {
        let mut path = OsString::from(backend);
        if let Some(existing) = env::var_os("PATH").filter(|path| !path.is_empty()) {
            path.push(":");
            path.push(existing);
        }
        command.env("PATH", path);
    }
    command
}

fn compile(tool: Tool) -> io::Result<i32> {
    let forward = || Ok(tool.exec(nvcc_command(&tool, &tool.args)));
    let Ok(effective) = effective_arguments(&tool.args) else {
        return forward();
    };
    let Some(build) = Compilation::inspect(&effective) else {
        return forward();
    };
    let Ok(cwd) = env::current_dir() else {
        return forward();
    };
    let mut args = Vec::new();
    if build.seed {
        args.push(format!("--frandom-seed=nvcc-{}", stable_id(&cwd, &build.sources)).into_bytes());
    }
    let scratch = if build.keep {
        let tmp = env::var_os("TMPDIR")
            .filter(|tmp| !tmp.is_empty())
            .unwrap_or_else(|| "/tmp".into());
        ScratchDirectory::acquire(
            PathBuf::from(tmp).join(format!("nvcc-keep-{}", stable_id(&cwd, &effective))),
        )
    } else {
        None
    };
    if let Some(scratch) = &scratch {
        args.push(b"--keep".to_vec());
        let mut keep_dir = OsString::from("--keep-dir=");
        keep_dir.push(scratch.path());
        args.push(keep_dir.into_vec());
    }
    args.extend_from_slice(&tool.args);

    let paths = if build.ptx {
        PathPrefixMap::from_environment()?
    } else {
        PathPrefixMap::default()
    };
    let outputs = if paths.is_empty() {
        Vec::new()
    } else {
        build.ptx_outputs()?
    };
    let command = nvcc_command(&tool, &args);
    if scratch.is_none() && outputs.is_empty() {
        return Ok(tool.exec(command));
    }
    let status = tool.run(command, scratch.as_ref().and_then(ScratchDirectory::lease))?;
    drop(scratch);
    let code = exit_status(status);
    if code == 0 {
        for output in outputs {
            output.rewrite_text("nvcc", |ptx| normalize_source_info(ptx, &paths, false))?;
        }
    }
    Ok(code)
}

fn main() -> ExitCode {
    wrapper_main("nvcc", compile)
}
