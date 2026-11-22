use crate::files::{anonymous_input, descriptor_path, read_regular};
use crate::space;
use std::ffi::OsStr;
use std::fs::File;
use std::io;
use std::os::unix::ffi::OsStrExt;

pub type Argument = Vec<u8>;
pub type Arguments = Vec<Argument>;

#[derive(Clone, Copy)]
pub enum Quote {
    Preserve,
    Discard,
}

// NVIDIA options files and flag variables use whitespace, double quotes and
// backslash escapes. Some tools discard an escaped double quote.
pub fn tokenize(text: &[u8], quotes: Quote) -> io::Result<Arguments> {
    let mut args = Vec::new();
    let mut word = None::<Argument>;
    let (mut quoted, mut escaped) = (false, false);
    for &byte in text {
        match byte {
            b'\\' if !escaped => escaped = true,
            b'"' if !escaped => {
                quoted = !quoted;
                word.get_or_insert_with(Vec::new);
            }
            byte if !escaped && !quoted && space(byte) => args.extend(word.take()),
            byte => {
                let word = word.get_or_insert_with(Vec::new);
                if byte != b'"' || matches!(quotes, Quote::Preserve) {
                    word.push(byte);
                }
                escaped = false;
            }
        }
    }
    if quoted || escaped {
        return Err(io::Error::other(
            "an options file ends in a backslash or a quotation",
        ));
    }
    args.extend(word);
    Ok(args)
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Plain,
    Operand,
    OptionsFile,
}

pub fn classify(name: &[u8], operands: &[&[u8]]) -> Kind {
    if matches!(name, b"-optf" | b"--options-file") {
        Kind::OptionsFile
    } else if operands.contains(&name) {
        Kind::Operand
    } else {
        Kind::Plain
    }
}

pub fn is_output(name: &[u8]) -> bool {
    matches!(name, b"-o" | b"--output-file")
}

pub fn informational(name: &[u8]) -> bool {
    matches!(name, b"-h" | b"--help" | b"-V" | b"--version")
}

pub fn split_option(arg: &[u8]) -> (&[u8], Option<&[u8]>) {
    arg.iter()
        .position(|&b| b == b'=')
        .map_or((arg, None), |i| (&arg[..i], Some(&arg[i + 1..])))
}

struct Item<'a> {
    name: &'a [u8],
    value: &'a [u8],
    kind: Kind,
    inline: bool,
}

fn next<'a>(
    args: &'a [Argument],
    index: &mut usize,
    classify: impl Fn(&[u8]) -> Kind,
) -> io::Result<Item<'a>> {
    let arg = args[*index].as_slice();
    let (name, value) = split_option(arg);
    let kind = classify(name);
    let inline = value.is_some();
    let value = match (kind, value) {
        (Kind::Plain, _) => arg,
        (_, Some(value)) => value,
        (_, None) => {
            *index += 1;
            args.get(*index).ok_or_else(|| {
                io::Error::other(format!(
                    "{} is missing its value",
                    OsStr::from_bytes(name).to_string_lossy()
                ))
            })?
        }
    };
    Ok(Item {
        name,
        value,
        kind,
        inline,
    })
}

fn depth_limit(depth: u8) -> io::Result<()> {
    if depth == 16 {
        return Err(io::Error::other("options files are nested too deeply"));
    }
    Ok(())
}

fn read_options(path: &[u8], quotes: Quote, remaining: &mut usize) -> io::Result<Arguments> {
    tokenize(&read_regular(OsStr::from_bytes(path), remaining)?, quotes)
}

pub fn expand(
    args: &[Argument],
    classify: impl Fn(&[u8]) -> Kind,
    quotes: Quote,
    mut remaining: usize,
) -> io::Result<Arguments> {
    fn append(
        output: &mut Arguments,
        args: &[Argument],
        classify: &impl Fn(&[u8]) -> Kind,
        quotes: Quote,
        remaining: &mut usize,
        depth: u8,
    ) -> io::Result<()> {
        depth_limit(depth)?;
        let mut index = 0;
        while index < args.len() {
            let start = index;
            let item = next(args, &mut index, classify)?;
            if item.kind == Kind::OptionsFile {
                for path in item.value.split(|&b| b == b',').filter(|p| !p.is_empty()) {
                    let file = read_options(path, quotes, remaining)?;
                    append(output, &file, classify, quotes, remaining, depth + 1)?;
                }
            } else {
                output.extend_from_slice(&args[start..=index]);
            }
            index += 1;
        }
        Ok(())
    }

    let mut output = Vec::new();
    append(&mut output, args, &classify, quotes, &mut remaining, 0)?;
    Ok(output)
}

pub fn last_output(
    args: &[Argument],
    classify: impl Fn(&[u8]) -> Kind,
) -> io::Result<Option<Argument>> {
    let args = expand(args, &classify, Quote::Discard, usize::MAX)?;
    let mut index = 0;
    let mut output = None;
    while index < args.len() {
        let item = next(&args, &mut index, &classify)?;
        if informational(item.name) {
            return Ok(None);
        }
        if is_output(item.name) {
            output = Some(item.value.to_vec());
        }
        index += 1;
    }
    Ok(output)
}

#[derive(Default)]
pub struct InputFiles(Vec<File>);

impl InputFiles {
    pub fn add(&mut self, file: File) -> Argument {
        let path = descriptor_path(&file);
        self.0.push(file);
        path
    }
}

fn encode(args: &[Argument]) -> Argument {
    let mut text = Vec::new();
    for arg in args {
        text.push(b'"');
        for &byte in arg {
            if matches!(byte, b'\\' | b'"') {
                text.push(b'\\');
            }
            text.push(byte);
        }
        text.extend_from_slice(b"\"\n");
    }
    text
}

pub enum RewriteError {
    Inspect,
    Input(io::Error),
}

// Keep the original position and nesting of options files. Large options
// files need to stay out of argv to avoid the kernel's argument size limit.
pub fn rewrite_options(
    args: &[Argument],
    classify: impl Fn(&[u8]) -> Kind,
    mut rewrite: impl FnMut(&[u8], Kind, &[u8], &mut InputFiles) -> io::Result<Option<Argument>>,
) -> Result<Option<(Arguments, InputFiles)>, RewriteError> {
    type RewriteResult<T> = Result<T, RewriteError>;
    fn rewrite_list(
        args: &mut [Argument],
        classify: &impl Fn(&[u8]) -> Kind,
        rewrite: &mut impl FnMut(&[u8], Kind, &[u8], &mut InputFiles) -> io::Result<Option<Argument>>,
        files: &mut InputFiles,
        remaining: &mut usize,
        depth: u8,
    ) -> RewriteResult<bool> {
        depth_limit(depth).map_err(|_| RewriteError::Inspect)?;
        let mut changed = false;
        let mut index = 0;
        while index < args.len() {
            let item = next(args, &mut index, classify).map_err(|_| RewriteError::Inspect)?;
            let replacement = if item.kind == Kind::OptionsFile {
                let mut paths = Vec::new();
                let mut updated = false;
                for (i, path) in item.value.split(|&b| b == b',').enumerate() {
                    if i > 0 {
                        paths.push(b',');
                    }
                    if path.is_empty() {
                        continue;
                    }
                    let mut nested = read_options(path, Quote::Discard, remaining)
                        .map_err(|_| RewriteError::Inspect)?;
                    if rewrite_list(&mut nested, classify, rewrite, files, remaining, depth + 1)? {
                        let file = anonymous_input(c"cuda-options", &encode(&nested))
                            .map_err(RewriteError::Input)?;
                        paths.extend(files.add(file));
                        updated = true;
                    } else {
                        paths.extend_from_slice(path);
                    }
                }
                updated.then_some(paths)
            } else {
                rewrite(item.name, item.kind, item.value, files).map_err(RewriteError::Input)?
            };
            // These tools discard escaped double quotes in options files.
            if let Some(replacement) = replacement.filter(|r| depth == 0 || !r.contains(&b'"')) {
                args[index] = if item.kind != Kind::Plain && item.inline {
                    [item.name, b"=", &replacement].concat()
                } else {
                    replacement
                };
                changed = true;
            }
            index += 1;
        }
        Ok(changed)
    }

    let mut args = args.to_vec();
    let mut files = InputFiles::default();
    let mut remaining = usize::MAX;
    if rewrite_list(
        &mut args,
        &classify,
        &mut rewrite,
        &mut files,
        &mut remaining,
        0,
    )? {
        return Ok(Some((args, files)));
    }
    Ok(None)
}
