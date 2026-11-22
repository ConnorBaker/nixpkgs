#[rustfmt::skip]
const OPERANDS: &[&[u8]] = &[
    b"-o", b"--output-file", b"-arch", b"--arch", b"-cpu-arch", b"--cpu-arch", b"-m", b"--machine", b"-L", b"--library-path",
    b"-l", b"--library", b"-Xnvvm", b"--Xnvvm", b"-Xptxas", b"--Xptxas", b"-Ofc", b"--Ofast-compile",
    b"-ghls", b"--gen-host-linker-script", b"-kernels-used", b"--kernels-used", b"-variables-used",
    b"--variables-used", b"--register-link-binaries", b"-nvvmpath", b"--nvvmpath", b"-uidx", b"--uidx-file",
    b"-maxrregcount", b"--maxrregcount", b"-split-compile", b"--split-compile",
    b"-split-compile-extended", b"--split-compile-extended", b"-time", b"--time",
];

use cuda_tool_wrapper::{
    arguments::{classify, last_output},
    artifact::{blank_store_hashes, edit_elf_sections, is_elf},
    files::Artifact,
    process::{exit_status, wrapper_main},
};
use std::ffi::OsString;
use std::io;
use std::os::unix::ffi::OsStringExt;
use std::process::ExitCode;

fn scrub(output: &mut (impl Artifact + ?Sized)) -> io::Result<()> {
    if is_elf(output)? {
        edit_elf_sections(output, b".note.nv.tkinfo", blank_store_hashes)?;
    } else if blank_store_hashes(&mut output.read(0, output.size())?) {
        // Live references in other formats, such as host linker scripts, cannot be scrubbed.
        return Err(io::Error::other(
            "the output isn't an ELF file, but refers to the Nix store",
        ));
    }
    Ok(())
}

fn main() -> ExitCode {
    wrapper_main("nvlink", |tool| {
        let command = tool.command(&tool.args);
        match last_output(&tool.args, |name| classify(name, OPERANDS))? {
            Some(path) => {
                tool.edit_output(command, OsString::from_vec(path).into(), |file| scrub(file))
            }
            None => Ok(exit_status(tool.run(command, None)?)),
        }
    })
}
