use crate::{
    arguments::{
        Argument, Arguments, Kind, Operands, Quote, operand_file, tokenize, visit_options_until,
    },
    files::{GeneratedFile, anonymous_file},
    path_prefix_map::PathPrefixMap,
    process::Tool,
    ptx::normalize_source_info,
    scratch::{ScratchDirectory, StableId},
};
use std::collections::HashSet;
use std::ffi::{OsStr, OsString};
use std::io::{self, Read, Seek, Write};
use std::ops::ControlFlow::{Break, Continue};
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::{env, fs};

fn bare_option(name: &[u8]) -> &[u8] {
    name.strip_prefix(b"--")
        .or_else(|| name.strip_prefix(b"-"))
        .unwrap_or_default()
}

fn classify(operands: &Operands<'_>, name: &[u8], next: Option<&[u8]>) -> io::Result<Kind> {
    match name {
        // A bare occurrence of these options defaults its value.
        b"-Ofc" | b"--Ofast-compile" | b"-hls" | b"--host-linker-script" => {
            Ok(if next.is_some_and(|value| !value.starts_with(b"-")) {
                Kind::Operand
            } else {
                Kind::Plain
            })
        }
        _ => operands.classify(name, next),
    }
}

#[rustfmt::skip]
const PASS_THROUGH: &[&[u8]] = &[
    b"dryrun", b"version", b"V", b"h", b"help", b"E", b"preprocess",
    b"M", b"MM", b"generate-dependencies", b"generate-nonsystem-dependencies",
    b"clean", b"clean-targets", b"code-ls", b"list-gpu-code", b"arch-ls", b"list-gpu-arch",
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
    fn inspect(args: &[Argument], operands: &Operands<'_>, cwd: &Path) -> io::Result<Option<Self>> {
        let mut supplied = flags("NVCC_PREPEND_FLAGS")?;
        let suffix = flags("NVCC_APPEND_FLAGS")?;
        let args = if supplied.is_empty() && suffix.is_empty() {
            args
        } else {
            supplied.extend_from_slice(args);
            supplied.extend(suffix);
            &supplied
        };

        let mut build = Self {
            sources: Vec::new(),
            scratch_id: StableId::new(cwd.as_os_str().as_bytes()),
            output: None,
            output_directory: PathBuf::new(),
            keep: true,
            seed: operands.requires(b"--frandom-seed"),
            ptx: false,
        };
        let mut explicit_language = false;
        let classify = |name: &[u8], next: Option<&[u8]>| classify(operands, name, next);
        let inspected = visit_options_until(args, classify, Quote::Preserve, |arg| {
            let name = bare_option(arg.name);
            if PASS_THROUGH.contains(&name) {
                return Break(());
            }
            for word in arg.words {
                build.scratch_id.push(word);
            }
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
            Continue(())
        })?;
        if inspected.is_break() {
            return Ok(None);
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
        Ok((!build.sources.is_empty()).then_some(build))
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
            .filter(|path| !stdout_path(path) && path != Path::new("/dev/null"))
            .map(GeneratedFile::new)
            .collect()
    }
}

fn stdout_path(path: &Path) -> bool {
    matches!(
        path.as_os_str().as_bytes(),
        b"-" | b"/dev/stdout" | b"/dev/fd/1" | b"/proc/self/fd/1"
    )
}

fn backend_bin(options: &[Argument]) -> io::Result<Option<&OsStr>> {
    match options {
        [] => Ok(None),
        [option] => option
            .strip_prefix(b"--nvcc-backend-bin=")
            .filter(|path| !path.contains(&b':'))
            .map(OsStr::from_bytes)
            .filter(|path| Path::new(path).is_absolute())
            .map(Some)
            .ok_or_else(|| io::Error::other("invalid nvcc backend directory")),
        _ => Err(io::Error::other("unexpected nvcc launcher options")),
    }
}

fn nvcc_command(tool: &Tool, prefix: &[Argument], backend: Option<&OsStr>) -> Command {
    let mut command = tool.command_from(prefix.iter().chain(&tool.args).map(Vec::as_slice));
    if let Some(backend) = backend {
        let path = env::var_os("PATH").filter(|path| !path.is_empty());
        let path = path.map_or_else(
            || OsString::from(backend),
            |path| [backend, &path].join(OsStr::new(":")),
        );
        command.env("PATH", path);
    }
    command
}

pub fn nvcc(mut tool: Tool) -> io::Result<i32> {
    tool.use_installed_name();
    let (operands, options) = operand_file(&tool)?;
    let backend = backend_bin(options)?;
    let table = fs::read(operands)?;
    let operands = Operands::new(&tool, &table);
    let forward = || Ok(tool.exec(nvcc_command(&tool, &[], backend)));
    let cwd = env::current_dir()?;
    let Some(build) = Compilation::inspect(&tool.args, &operands, &cwd)? else {
        return forward();
    };
    let paths = if build.seed || build.ptx {
        PathPrefixMap::from_environment()?
    } else {
        PathPrefixMap::default()
    };
    let mut prefix = Vec::new();
    if build.seed {
        let source = &build.sources[0];
        let mapped = paths.remap(cwd.join(OsStr::from_bytes(source)).as_os_str().as_bytes());
        let cwd = cwd.as_os_str().as_bytes();
        let mapped_directory = paths.remap(cwd);
        let directory = if mapped.is_some() {
            b""
        } else {
            mapped_directory.as_deref().unwrap_or(cwd)
        };
        let mut seed = StableId::new(directory);
        seed.push(mapped.as_deref().unwrap_or(source));
        prefix.push(format!("--frandom-seed=nvcc-{}", seed.finish()).into_bytes());
    }
    let scratch = if build.keep {
        let tmp = env::var_os("TMPDIR")
            .filter(|tmp| !tmp.is_empty())
            .unwrap_or_else(|| "/tmp".into());
        ScratchDirectory::acquire_with_marker(
            PathBuf::from(tmp).join(format!("nvcc-keep-{}", build.scratch_id.finish())),
            ".nix-cuda-wrapper",
        )
    } else {
        None
    };
    if let Some(scratch) = &scratch {
        prefix.push(b"--keep".to_vec());
        let mut keep_dir = OsString::from("--keep-dir=");
        keep_dir.push(scratch.path());
        prefix.push(keep_dir.into_vec());
    }

    let outputs = if build.ptx && !paths.is_empty() {
        build.ptx_outputs()?
    } else {
        Vec::new()
    };
    let mut command = nvcc_command(&tool, &prefix, backend);
    let stdout =
        if build.ptx && !paths.is_empty() && build.output.as_deref().is_some_and(stdout_path) {
            let file = anonymous_file(c"nvcc-ptx-stdout")?;
            command.stdout(file.try_clone()?);
            Some(file)
        } else {
            None
        };
    if scratch.is_none() && outputs.is_empty() && stdout.is_none() {
        return Ok(tool.exec(command));
    }
    tool.run_then(command, scratch, || {
        for output in outputs {
            output.edit("nvcc", |artifact| {
                artifact.rewrite(|ptx| normalize_source_info(ptx, &paths, false))
            })?;
        }
        if let Some(mut file) = stdout {
            let mut ptx = Vec::new();
            file.rewind()?;
            file.read_to_end(&mut ptx)?;
            let mapped = normalize_source_info(&ptx, &paths, false)?;
            io::stdout()
                .lock()
                .write_all(mapped.as_deref().unwrap_or(&ptx))?;
        }
        Ok(())
    })
}
