mod operands;
pub(crate) use operands::{Operands, operand_file};

use crate::files::InputFiles;
use crate::process::PreparedArgs;
use std::ffi::{CStr, OsStr};
use std::io;
use std::ops::ControlFlow;
use std::os::unix::ffi::OsStrExt;
use std::path::PathBuf;
pub use tool_wrapper::process::{Argument, Arguments};
use tool_wrapper::quoting::{Escape, double_quoted_lines, split_words};
use tool_wrapper::response::{self, Group, Limits, Syntax, option_group};
pub use tool_wrapper::response::{OptionArg, OptionKind as Kind};

#[derive(Clone, Copy)]
pub enum Quote {
    Preserve,
    Discard,
}

// NVIDIA options files and flag variables use whitespace, double quotes and
// backslash escapes. Some tools discard an escaped double quote.
pub fn tokenize(text: &[u8], quotes: Quote) -> io::Result<Arguments> {
    split_words(text, b"\"", |_, escaped| match (escaped, quotes) {
        (b'"', Quote::Discard) => Escape::Drop,
        _ => Escape::Keep,
    })
    .ok_or_else(|| io::Error::other("an options file ends in a backslash or a quotation"))
}

pub(crate) const OPTIONS_FILE: Kind = Kind::Files {
    separator: Some(b','),
};

pub fn classify(name: &[u8], has_operand: impl FnOnce(&[u8]) -> bool) -> Kind {
    match name {
        b"-optf" | b"--options-file" => OPTIONS_FILE,
        _ if has_operand(name) => Kind::Operand,
        _ => Kind::Plain,
    }
}

pub fn informational(name: &[u8]) -> bool {
    matches!(name, b"-h" | b"--help" | b"-V" | b"--version")
}

struct Options<F> {
    classify: F,
    quotes: Quote,
}

impl<F: Fn(&[u8], Option<&[u8]>) -> io::Result<Kind>> Syntax for Options<F> {
    type Word<'a> = OptionArg<'a>;

    const STAGED_NAME: &'static CStr = c"cuda-options";

    fn next<'a>(&self, words: &'a [Argument]) -> io::Result<Group<'a, Self::Word<'a>>> {
        let word = words[0].as_slice();
        let (name, next) = match word.iter().position(|&byte| byte == b'=') {
            Some(equal) => (&word[..equal], None),
            None => (word, words.get(1).map(Vec::as_slice)),
        };
        let kind = (self.classify)(name, next)?;
        option_group(words, |_| kind)
    }

    fn decode(&self, contents: &[u8]) -> io::Result<Arguments> {
        tokenize(contents, self.quotes)
    }

    fn encode(&self, words: &[Argument]) -> Vec<u8> {
        double_quoted_lines(words)
    }

    fn can_encode(&self, value: &[u8]) -> bool {
        // Escaped double quotes do not survive these options files.
        !value.contains(&b'"')
    }
}

pub(crate) fn visit_options_until(
    args: &[Argument],
    classify: impl Fn(&[u8], Option<&[u8]>) -> io::Result<Kind>,
    quotes: Quote,
    visit: impl FnMut(OptionArg<'_>) -> ControlFlow<()>,
) -> io::Result<ControlFlow<()>> {
    response::visit_until(args, Options { classify, quotes }, Limits::default(), visit)
}

pub fn last_output(args: &[Argument], free_form_operands: &[&[u8]]) -> io::Result<Option<PathBuf>> {
    let is_output = |name: &[u8]| matches!(name, b"-o" | b"--output-file");
    let mut output = None;
    let mut query = false;
    let _ = visit_options_until(
        args,
        |name, _| {
            Ok(classify(name, |name| {
                is_output(name) || free_form_operands.contains(&name)
            }))
        },
        Quote::Discard,
        |arg| {
            query |= informational(arg.name);
            if is_output(arg.name) {
                output = Some(PathBuf::from(OsStr::from_bytes(arg.value)));
            }
            ControlFlow::Continue(())
        },
    )?;
    Ok(if query { None } else { output })
}

pub fn rewrite_options(
    args: &[Argument],
    classify: impl Fn(&[u8]) -> Kind,
    mut rewrite: impl FnMut(&OptionArg<'_>, &mut InputFiles) -> io::Result<Option<Argument>>,
) -> io::Result<Option<PreparedArgs>> {
    rewrite_options_until(
        args,
        |name, _| Ok(classify(name)),
        |arg, files| rewrite(arg, files).map(ControlFlow::Continue),
    )
}

pub(crate) fn rewrite_options_until(
    args: &[Argument],
    classify: impl Fn(&[u8], Option<&[u8]>) -> io::Result<Kind>,
    mut rewrite: impl FnMut(
        &OptionArg<'_>,
        &mut InputFiles,
    ) -> io::Result<ControlFlow<(), Option<Argument>>>,
) -> io::Result<Option<PreparedArgs>> {
    response::rewrite_required_until(
        args,
        Options {
            classify,
            quotes: Quote::Discard,
        },
        Limits::default(),
        |arg, files| rewrite(&arg, files),
    )
}
