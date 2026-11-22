use crate::files::{anonymous_input, descriptor_path, read_regular};
use crate::{push_quoted, space};
use std::ffi::OsStr;
use std::fs::File;
use std::io;
use std::os::unix::ffi::OsStrExt;
use std::path::PathBuf;

pub type Argument = Vec<u8>;
pub type Arguments = Vec<Argument>;
type Classify = fn(&[u8]) -> Kind;

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
    let mut quoted = false;
    let mut bytes = text.iter().copied();
    while let Some(byte) = bytes.next() {
        match byte {
            b'\\' => {
                let escaped = bytes.next().ok_or_else(unterminated)?;
                let word = word.get_or_insert_with(Vec::new);
                if escaped != b'"' || matches!(quotes, Quote::Preserve) {
                    word.push(escaped);
                }
            }
            b'"' => {
                quoted = !quoted;
                word.get_or_insert_with(Vec::new);
            }
            byte if !quoted && space(byte) => args.extend(word.take()),
            byte => word.get_or_insert_with(Vec::new).push(byte),
        }
    }
    if quoted {
        return Err(unterminated());
    }
    args.extend(word);
    Ok(args)
}

fn unterminated() -> io::Error {
    io::Error::other("an options file ends in a backslash or a quotation")
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Plain,
    Operand,
    OptionsFile,
}

pub fn classify(name: &[u8], operands: &[&[u8]]) -> Kind {
    match name {
        b"-optf" | b"--options-file" => Kind::OptionsFile,
        _ if operands.contains(&name) => Kind::Operand,
        _ => Kind::Plain,
    }
}

pub fn informational(name: &[u8]) -> bool {
    matches!(name, b"-h" | b"--help" | b"-V" | b"--version")
}

pub struct OptionArg<'a> {
    pub name: &'a [u8],
    pub value: &'a [u8],
    pub kind: Kind,
    words: &'a [Argument],
}

pub fn scan(
    mut words: &[Argument],
    classify: Classify,
) -> impl Iterator<Item = io::Result<OptionArg<'_>>> {
    std::iter::from_fn(move || {
        let word = words.first()?.as_slice();
        let (name, inline) = match word.iter().position(|&byte| byte == b'=') {
            Some(i) => (&word[..i], Some(&word[i + 1..])),
            None => (word, None),
        };
        let kind = classify(name);
        let (value, count) = match (kind, inline) {
            (Kind::Plain, _) => (word, 1),
            (_, Some(value)) => (value, 1),
            (_, None) if words.len() > 1 => (words[1].as_slice(), 2),
            _ => {
                words = &[];
                return Some(Err(io::Error::other(format!(
                    "{} is missing its value",
                    OsStr::from_bytes(name).to_string_lossy()
                ))));
            }
        };
        let (original, rest) = words.split_at(count);
        words = rest;
        Some(Ok(OptionArg {
            name,
            value,
            kind,
            words: original,
        }))
    })
}

fn check_depth(depth: u8) -> io::Result<()> {
    if depth == 16 {
        return Err(io::Error::other("options files are nested too deeply"));
    }
    Ok(())
}

fn read_options(path: &[u8], quotes: Quote, remaining: &mut usize) -> io::Result<Arguments> {
    tokenize(&read_regular(OsStr::from_bytes(path), remaining)?, quotes)
}

struct Options {
    classify: Classify,
    quotes: Quote,
    remaining: usize,
}

impl Options {
    fn visit(
        &mut self,
        args: &[Argument],
        depth: u8,
        visit: &mut impl FnMut(OptionArg<'_>),
    ) -> io::Result<()> {
        check_depth(depth)?;
        for arg in scan(args, self.classify) {
            let arg = arg?;
            if arg.kind == Kind::OptionsFile {
                for path in arg.value.split(|&b| b == b',').filter(|p| !p.is_empty()) {
                    let nested = read_options(path, self.quotes, &mut self.remaining)?;
                    self.visit(&nested, depth + 1, visit)?;
                }
            } else {
                visit(arg);
            }
        }
        Ok(())
    }
}

pub fn expand(
    args: &[Argument],
    classify: Classify,
    quotes: Quote,
    remaining: usize,
) -> io::Result<Arguments> {
    let mut output = Vec::new();
    Options {
        classify,
        quotes,
        remaining,
    }
    .visit(args, 0, &mut |arg| output.extend_from_slice(arg.words))?;
    Ok(output)
}

pub fn last_output(args: &[Argument], classify: Classify) -> io::Result<Option<PathBuf>> {
    let mut output = None;
    let mut query = false;
    Options {
        classify,
        quotes: Quote::Discard,
        remaining: usize::MAX,
    }
    .visit(args, 0, &mut |arg| {
        query |= informational(arg.name);
        if matches!(arg.name, b"-o" | b"--output-file") {
            output = Some(PathBuf::from(OsStr::from_bytes(arg.value)));
        }
    })?;
    Ok(if query { None } else { output })
}

#[derive(Default)]
pub struct InputFiles(Vec<File>);

impl InputFiles {
    pub fn add(&mut self, file: File) -> Argument {
        let path = descriptor_path(&file).into_bytes();
        self.0.push(file);
        path
    }
}

enum RewriteError {
    Inspect,
    Input(io::Error),
}

type RewriteResult<T> = Result<T, RewriteError>;
type RewriteInput = io::Result<Option<Argument>>;

pub struct RewrittenArgs {
    pub args: Arguments,
    // Keep the anonymous inputs available through exec.
    _files: InputFiles,
}

struct Rewriter<F> {
    classify: Classify,
    rewrite: F,
    remaining: usize,
    files: InputFiles,
}

impl<F: FnMut(OptionArg<'_>, &mut InputFiles) -> RewriteInput> Rewriter<F> {
    // Keep rewritten options in files. Moving them to argv would introduce
    // the kernel's argument size limit and could change option precedence.
    fn list(&mut self, args: &[Argument], depth: u8) -> RewriteResult<Option<Arguments>> {
        check_depth(depth).map_err(|_| RewriteError::Inspect)?;
        let mut output = Vec::new();
        let mut changed = false;
        for arg in scan(args, self.classify) {
            let arg = arg.map_err(|_| RewriteError::Inspect)?;
            let words = arg.words;
            let name = arg.name;
            let inline = arg.kind != Kind::Plain && words.len() == 1;
            let replacement = if arg.kind == Kind::OptionsFile {
                self.file_list(arg.value, depth + 1)?
            } else {
                (self.rewrite)(arg, &mut self.files).map_err(RewriteError::Input)?
            };
            // Escaped double quotes do not survive these options files.
            if let Some(replacement) = replacement.filter(|r| depth == 0 || !r.contains(&b'"')) {
                output.extend_from_slice(&words[..words.len() - 1]);
                output.push(if inline {
                    [name, b"=", &replacement].concat()
                } else {
                    replacement
                });
                changed = true;
            } else {
                output.extend_from_slice(words);
            }
        }
        Ok(changed.then_some(output))
    }

    fn file_list(&mut self, value: &[u8], depth: u8) -> RewriteResult<Option<Argument>> {
        let mut paths = Vec::new();
        let mut changed = false;
        for (index, path) in value.split(|&b| b == b',').enumerate() {
            if index != 0 {
                paths.push(b',');
            }
            if path.is_empty() {
                continue;
            }
            let args = read_options(path, Quote::Discard, &mut self.remaining)
                .map_err(|_| RewriteError::Inspect)?;
            if let Some(rewritten) = self.list(&args, depth)? {
                let mut text = Vec::new();
                for word in rewritten {
                    push_quoted(&mut text, &word);
                    text.push(b'\n');
                }
                let file = anonymous_input(c"cuda-options", &text).map_err(RewriteError::Input)?;
                paths.extend(self.files.add(file));
                changed = true;
            } else {
                paths.extend_from_slice(path);
            }
        }
        Ok(changed.then_some(paths))
    }
}

pub fn rewrite_options(
    args: &[Argument],
    classify: Classify,
    rewrite: impl FnMut(OptionArg<'_>, &mut InputFiles) -> RewriteInput,
) -> io::Result<Option<RewrittenArgs>> {
    let mut rewriter = Rewriter {
        classify,
        rewrite,
        remaining: usize::MAX,
        files: InputFiles::default(),
    };
    match rewriter.list(args, 0) {
        Ok(Some(args)) => Ok(Some(RewrittenArgs {
            args,
            _files: rewriter.files,
        })),
        Ok(None) | Err(RewriteError::Inspect) => Ok(None),
        Err(RewriteError::Input(error)) => Err(error),
    }
}
