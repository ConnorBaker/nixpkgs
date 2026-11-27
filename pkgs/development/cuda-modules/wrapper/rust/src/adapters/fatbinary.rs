use tool_wrapper::process::Tool;
#[rustfmt::skip]
const OPERANDS: &[&[u8]] = &[
    b"-ident", b"--ident", b"-image3", b"--image3", b"-image2", b"--image2", b"-create", b"--create",
    b"-fatbin", b"--embedded-fatbin", b"-cmdline", b"--cmdline", b"-cicc-cmdline", b"--cicc-cmdline",
    b"-tileir-cmdline", b"--tileir-cmdline",
];

use crate::{
    arguments::{classify, rewrite_options},
    files::InputFiles,
    path_prefix_map::PathPrefixMap,
    ptx::rewritten_input,
};
use std::io;

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
    if let Some(range) = image.subslice_range(filename)
        && let Some(path) = rewritten_input(files, filename, paths, false)?
    {
        return Ok(Some(
            [&image[..range.start], &path, &image[range.end..]].concat(),
        ));
    }
    Ok(None)
}

pub fn fatbinary(tool: Tool) -> io::Result<i32> {
    let paths = PathPrefixMap::from_environment()?;
    if paths.is_empty() {
        return Ok(tool.forward());
    }
    let rewritten = rewrite_options(
        &tool.args,
        |name| classify(name, |name| OPERANDS.contains(&name)),
        |arg, files| match arg.name {
            b"-ident" | b"--ident" => Ok(paths.remap(arg.value)),
            b"-image2" | b"--image2" | b"-image3" | b"--image3" => {
                remap_image(arg.value, &paths, files)
            }
            _ => Ok(None),
        },
    )?;
    Ok(tool.with_prepared_args(rewritten).forward())
}
