#[rustfmt::skip]
const OPERANDS: &[&[u8]] = &[
    b"-ident", b"--ident", b"-image3", b"--image3", b"-image2", b"--image2", b"-create", b"--create",
    b"-fatbin", b"--embedded-fatbin", b"-cmdline", b"--cmdline", b"-cicc-cmdline", b"--cicc-cmdline",
    b"-tileir-cmdline", b"--tileir-cmdline", b"-compress", b"--compress",
    b"-compress-mode", b"--compress-mode",
];

use cuda_tool_wrapper::{
    arguments::{InputFiles, RewriteError, classify, rewrite_options},
    process::wrapper_main,
    ptx::{PathPrefixMap, rewritten_input},
};
use std::io;
use std::process::ExitCode;

fn remap_image(
    image: &[u8],
    paths: &PathPrefixMap,
    files: &mut InputFiles,
) -> io::Result<Option<Vec<u8>>> {
    let mut fields = image.split(|&b| b == b',');
    if !fields.clone().any(|field| field == b"kind=ptx") {
        return Ok(None);
    }
    let Some(filename) = fields.find_map(|field| field.strip_prefix(b"file=")) else {
        return Ok(None);
    };
    if fields.any(|field| field.starts_with(b"file=")) {
        return Ok(None);
    }
    let Some(file) = rewritten_input(filename, paths, false)? else {
        return Ok(None);
    };
    let offset = filename.as_ptr() as usize - image.as_ptr() as usize;
    Ok(Some(
        [
            &image[..offset],
            &files.add(file),
            &image[offset + filename.len()..],
        ]
        .concat(),
    ))
}

fn main() -> ExitCode {
    wrapper_main("fatbinary", |tool| {
        let paths = PathPrefixMap::from_environment()?;
        if paths.is_empty() {
            return Ok(tool.exec(tool.command(&tool.args)));
        }
        let rewritten = rewrite_options(
            &tool.args,
            |name| classify(name, OPERANDS),
            |name, _, value, files| match name {
                b"-ident" | b"--ident" => Ok(paths.remap(value)),
                b"-image2" | b"--image2" | b"-image3" | b"--image3" => {
                    remap_image(value, &paths, files)
                }
                _ => Ok(None),
            },
        );
        match rewritten {
            Ok(Some((args, _files))) => Ok(tool.exec(tool.command(&args))),
            Err(RewriteError::Input(error)) => Err(error),
            _ => Ok(tool.exec(tool.command(&tool.args))),
        }
    })
}
