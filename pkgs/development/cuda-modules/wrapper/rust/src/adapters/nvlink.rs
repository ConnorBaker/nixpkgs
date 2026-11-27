use tool_wrapper::process::Tool;
// These values can look like a wrapper-relevant option. A valid enum or
// numeric operand cannot, and -ghls and -Ofc also accept no separate value.
#[rustfmt::skip]
const FREE_FORM_OPERANDS: &[&[u8]] = &[
    b"-L", b"--library-path", b"-l", b"--library",
    b"-Xnvvm", b"--Xnvvm", b"-Xptxas", b"--Xptxas",
    b"-kernels-used", b"--kernels-used", b"-variables-used", b"--variables-used",
    b"--register-link-binaries", b"-nvvmpath", b"--nvvmpath", b"-uidx", b"--uidx-file",
    b"-time", b"--time", b"-host-ccbin", b"--host-ccbin",
];

use crate::{
    arguments::last_output,
    artifact::{Artifact, blank_store_hashes, edit_elf_sections, is_elf},
};
use std::io;
use tool_wrapper::nix_store::contains_store_hash_candidate;

fn scrub(output: &mut Artifact<'_>) -> io::Result<()> {
    if is_elf(output)? {
        edit_elf_sections(output, b".note.nv.tkinfo", blank_store_hashes)?;
    } else if contains_store_hash_candidate(output)? {
        // Other formats, such as host linker scripts, can use references as inputs.
        return Err(io::Error::other(
            "the non-ELF output contains a possible Nix store reference",
        ));
    }
    Ok(())
}

pub fn nvlink(tool: Tool) -> io::Result<i32> {
    match last_output(&tool.args, FREE_FORM_OPERANDS)? {
        Some(path) => tool.edit_output(tool.command(&tool.args), path, scrub),
        None => tool.supervise(),
    }
}
