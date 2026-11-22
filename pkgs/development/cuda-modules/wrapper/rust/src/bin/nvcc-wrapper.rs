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
    b"keep-dir", b"frandom-seed", b"x", b"o", b"output-file", b"odir", b"output-directory",
];

use cuda_tool_wrapper::{
    arguments::{Argument, Arguments, Kind, Quote, tokenize, visit_options},
    files::{GeneratedFile, special_file},
    process::{Tool, exit_status, wrapper_main},
    ptx::{PathPrefixMap, normalize_source_info},
    scratch::{ScratchDirectory, StableId},
};
use std::collections::HashSet;
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

fn classify(name: &[u8]) -> Kind {
    match bare_option(name) {
        b"optf" | b"options-file" => Kind::OptionsFile,
        name if OPERANDS.contains(&name) => Kind::Operand,
        _ => Kind::Plain,
    }
}

#[rustfmt::skip]
const PASS_THROUGH: &[&[u8]] = &[
    b"dryrun", b"version", b"V", b"h", b"help", b"E", b"preprocess",
    b"M", b"MM", b"generate-dependencies", b"generate-nonsystem-dependencies",
    b"clean", b"clean-targets",
];

fn flags(name: &str) -> io::Result<Arguments> {
    tokenize(
        env::var_os(name).as_deref().unwrap_or_default().as_bytes(),
        Quote::Preserve,
    )
}

struct Compilation {
    sources: Arguments,
    scratch_id: StableId,
    output: Option<PathBuf>,
    output_directory: PathBuf,
    keep: bool,
    seed: bool,
    ptx: bool,
}

impl Compilation {
    fn inspect(args: &[Argument], cwd: &Path) -> Option<Self> {
        let mut supplied = flags("NVCC_PREPEND_FLAGS").ok()?;
        supplied.extend_from_slice(args);
        supplied.extend(flags("NVCC_APPEND_FLAGS").ok()?);

        let mut build = Self {
            sources: Vec::new(),
            scratch_id: StableId::new(cwd),
            output: None,
            output_directory: PathBuf::new(),
            keep: true,
            seed: option_env!("NVCC_HAS_RANDOM_SEED") == Some("true"),
            ptx: false,
        };
        let mut explicit_language = false;
        let mut bypass = false;
        visit_options(
            &supplied,
            classify,
            Quote::Preserve,
            4 * 1024 * 1024,
            |arg| {
                for word in arg.words {
                    build.scratch_id.push(word);
                }
                let name = bare_option(arg.name);
                bypass |= PASS_THROUGH.contains(&name);
                let path = || PathBuf::from(OsStr::from_bytes(arg.value));
                match name {
                    b"o" | b"output-file" => build.output = Some(path()),
                    b"odir" | b"output-directory" => build.output_directory = path(),
                    b"x" => explicit_language = matches!(arg.value, b"cu" | b"c++" | b"c"),
                    b"keep" | b"keep-dir" | b"save-temps" | b"objdir-as-tempdir" | b"objtemp" => {
                        build.keep = false
                    }
                    b"frandom-seed" => build.seed = false,
                    b"ptx" => build.ptx = true,
                    b"" if !arg.value.is_empty() && !arg.value.starts_with(b"-") => {
                        build.sources.push(arg.value.to_vec())
                    }
                    _ => {}
                }
            },
        )
        .ok()?;
        if bypass {
            return None;
        }

        const SOURCE_EXTENSIONS: &[&[u8]] =
            &[b"cu", b"c", b"cc", b"cxx", b"cpp", b"c++", b"C", b"CPP"];
        if !explicit_language {
            build.sources.retain(|source| {
                let path = Path::new(OsStr::from_bytes(source));
                SOURCE_EXTENSIONS.contains(&path.extension().unwrap_or_default().as_bytes())
            });
        }
        let mut stems = HashSet::new();
        build.keep &= build
            .sources
            .iter()
            .all(|source| stems.insert(Path::new(OsStr::from_bytes(source)).file_stem()));
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
    let mut command = tool.command(args);
    if let Some(backend) = option_env!("NVCC_BACKEND_BIN") {
        let path = env::var_os("PATH").filter(|path| !path.is_empty());
        let path = path.map_or_else(
            || OsString::from(backend),
            |path| [OsStr::new(backend), &path].join(OsStr::new(":")),
        );
        command.env("PATH", path);
    }
    command
}

fn compile(mut tool: Tool) -> io::Result<i32> {
    tool.use_installed_name();
    let forward = || Ok(tool.exec(nvcc_command(&tool, &tool.args)));
    let Ok(cwd) = env::current_dir() else {
        return forward();
    };
    let Some(build) = Compilation::inspect(&tool.args, &cwd) else {
        return forward();
    };
    let mut args = Vec::new();
    if build.seed {
        let mut seed = StableId::new(&cwd);
        seed.push(&build.sources[0]);
        args.push(format!("--frandom-seed=nvcc-{}", seed.finish()).into_bytes());
    }
    let scratch = if build.keep {
        let tmp = env::var_os("TMPDIR")
            .filter(|tmp| !tmp.is_empty())
            .unwrap_or_else(|| "/tmp".into());
        ScratchDirectory::acquire(
            PathBuf::from(tmp).join(format!("nvcc-keep-{}", build.scratch_id.finish())),
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
