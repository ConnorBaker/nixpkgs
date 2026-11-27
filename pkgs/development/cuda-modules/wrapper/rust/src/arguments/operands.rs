use super::{Argument, Kind, OPTIONS_FILE};
use crate::files::anonymous_file;
use crate::process::{Tool, exit_status};
use std::cell::RefCell;
use std::collections::HashMap;
use std::ffi::OsStr;
use std::io::{self, Read, Seek};
use std::os::unix::{
    ffi::OsStrExt,
    process::{CommandExt, ExitStatusExt},
};
use std::path::Path;
use std::process::{Command, Stdio};

pub(crate) fn operand_file(tool: &Tool) -> io::Result<(&Path, &[Argument])> {
    tool.launcher_options()
        .split_first()
        .and_then(|(first, options)| {
            let path = Path::new(OsStr::from_bytes(first.strip_prefix(b"--operands-file=")?));
            path.is_absolute().then_some((path, options))
        })
        .ok_or_else(|| io::Error::other("missing CUDA operand file in launcher"))
}

pub(crate) struct Operands<'a> {
    tool: &'a Tool,
    documented: HashMap<&'a [u8], bool>,
    discovered: RefCell<HashMap<(Argument, bool), Kind>>,
}

impl<'a> Operands<'a> {
    pub(crate) fn new(tool: &'a Tool, table: &'a [u8]) -> Self {
        let documented = table
            .split(u8::is_ascii_whitespace)
            .filter_map(|line| match line {
                [b'1', name @ ..] => Some((name, true)),
                [b'0', name @ ..] => Some((name, false)),
                _ => None,
            })
            .collect();
        Self {
            tool,
            documented,
            discovered: RefCell::default(),
        }
    }

    pub(crate) fn requires(&self, name: &[u8]) -> bool {
        self.documented.get(name) == Some(&true)
    }

    pub(crate) fn classify(&self, name: &[u8], next: Option<&[u8]>) -> io::Result<Kind> {
        if matches!(name, b"-optf" | b"--options-file") {
            return Ok(OPTIONS_FILE);
        }
        if let Some(required) = self.documented.get(name) {
            return Ok(if *required {
                Kind::Operand
            } else {
                Kind::Plain
            });
        }
        let Some(next) = next.filter(|_| name.starts_with(b"-") && name != b"-") else {
            return Ok(Kind::Plain);
        };
        let key = (name.to_vec(), next.starts_with(b"-"));
        if let Some(kind) = self.discovered.borrow().get(&key) {
            return Ok(*kind);
        }
        let kind = self.discover(name, key.1)?;
        self.discovered.borrow_mut().insert(key, kind);
        Ok(kind)
    }

    fn discover(&self, name: &[u8], next_is_flag: bool) -> io::Result<Kind> {
        // A required operand consumes the first switch, or reports it as an
        // invalid value. Otherwise the parser rejects that switch itself.
        const FIRST: &[u8] = b"--nix-cuda-arity-probe-first";
        const SECOND: &[u8] = b"--nix-cuda-arity-probe-second";
        const NO_INPUT: &[u8] = b"/dev/null/nix-cuda-arity-probe";

        let nvcc = self.tool.name() == "nvcc";
        let unknown = |diagnostic: &[u8], option: &[u8]| {
            let spelling = if nvcc { option } else { &option[1..] };
            diagnostic
                .strip_prefix(b"Unknown option '")
                .and_then(|rest| rest.strip_suffix(b"'"))
                == Some(spelling)
        };
        let unresolved = || {
            io::Error::other(format!(
                "cannot determine whether {} takes a separate operand",
                OsStr::from_bytes(name).to_string_lossy(),
            ))
        };

        let output = self.probe([name, FIRST, SECOND])?;
        let rejected = self.diagnostic(&output).ok_or_else(unresolved)?;
        if unknown(rejected, name) {
            return Ok(Kind::Plain);
        }
        if unknown(rejected, SECOND) || rejected_value(rejected, FIRST) {
            return Ok(Kind::Operand);
        }
        if !unknown(rejected, FIRST) {
            return Err(unresolved());
        }
        if next_is_flag {
            return Ok(Kind::Plain);
        }

        // Some optional operands accept only a non-switch word. Try a path
        // that cannot exist, with no compilation or usable output.
        let mode = if nvcc {
            b"--dryrun".as_slice()
        } else {
            b"--output-file=/dev/null"
        };
        let output = self.probe([mode, name, NO_INPUT])?;
        match self.diagnostic(&output) {
            Some(
                b"Input file '/dev/null/nix-cuda-arity-probe' could not be opened"
                | b"Don't know what to do with '/dev/null/nix-cuda-arity-probe'",
            ) => Ok(Kind::Plain),
            Some(error)
                if rejected_value(error, NO_INPUT)
                    || (nvcc && error.starts_with(b"No input files specified")) =>
            {
                Ok(Kind::Operand)
            }
            _ => Err(unresolved()),
        }
    }

    fn diagnostic<'b>(&self, log: &'b [u8]) -> Option<&'b [u8]> {
        log.split(|&byte| byte == b'\n').find_map(|line| {
            line.strip_prefix(self.tool.name().as_bytes())?
                .strip_prefix(b" fatal   : ")
        })
    }

    fn probe(&self, arguments: [&[u8]; 3]) -> io::Result<Vec<u8>> {
        // A probe needs its own stderr even when the caller closed theirs.
        let vendor = self.tool.command_from([]);
        let executable = Path::new(vendor.get_program());
        let mut log = anonymous_file(c"cuda-operand-probe")?;
        let mut command = Command::new(executable);
        command
            .arg0(executable.with_file_name(self.tool.name()))
            .args(arguments.map(OsStr::from_bytes))
            .env("LC_ALL", "C")
            .env_remove("NVCC_PREPEND_FLAGS")
            .env_remove("NVCC_APPEND_FLAGS")
            .current_dir("/")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(log.try_clone()?);
        let status = self.tool.run(command, None)?;
        if status.signal().is_some() {
            drop(log);
            return Err(io::Error::other(format!(
                "operand probe exited with status {}",
                exit_status(status)
            )));
        }
        let mut output = Vec::new();
        log.rewind()?;
        log.read_to_end(&mut output)?;
        Ok(output)
    }
}

fn rejected_value(diagnostic: &[u8], value: &[u8]) -> bool {
    let mut parts = diagnostic.splitn(3, |&byte| byte == b'\'');
    match (parts.next(), parts.next(), parts.next()) {
        (Some(b"Value "), Some(actual), Some(suffix)) => {
            actual == value && suffix.starts_with(b" is not defined for option ")
        }
        (Some(b""), Some(actual), Some(suffix)) => {
            actual == value && suffix.starts_with(b": expected ")
        }
        _ => false,
    }
}
