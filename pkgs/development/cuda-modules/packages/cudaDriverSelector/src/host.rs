use super::{PATH_MAX, io, join_path, policy};
use alloc::{ffi::CString, vec::Vec};
use core::{
    ffi::{CStr, c_char},
    str,
};
use rustix::fs::{self, AtFlags, CWD, Mode, OFlags};

#[derive(Clone, Copy, PartialEq)]
struct Id(u64, u64, u64);
fn same(path: &CStr, id: Id) -> bool {
    fs::statat(CWD, path, AtFlags::empty()).is_ok_and(|m| {
        Id(
            fs::major(m.st_dev).into(),
            fs::minor(m.st_dev).into(),
            m.st_ino,
        ) == id
    })
}
// An earlier auditor can substitute a different ELF while glibc keeps the
// original l_name. The dynamic segment identifies the file actually mapped.
fn mapped(address: usize) -> Option<Id> {
    let f = fs::open(
        c"/proc/self/maps",
        OFlags::RDONLY | OFlags::CLOEXEC,
        Mode::empty(),
    )
    .ok()?;
    // All five numeric fields fit in this prefix regardless of pathname length.
    io::lines(f, 256, true, |line| {
        let hex = |s| u64::from_str_radix(s, 16).ok();
        let mut fields = line
            .split(|&c| c == b' ')
            .filter(|s| !s.is_empty())
            .map(|s| str::from_utf8(s).ok());
        let (low, high) = fields.next()??.split_once('-')?;
        if !(hex(low)?..hex(high)?).contains(&(address as u64)) {
            return None;
        }
        let (major, minor) = fields.nth(2)??.split_once(':')?;
        Some(Id(hex(major)?, hex(minor)?, fields.next()??.parse().ok()?))
    })
}
fn dirs() -> impl Iterator<Item = &'static [u8]> {
    env!("NIX_CUDA_HOST_DIRS")
        .as_bytes()
        .split(|&c| c == b'\n')
        .filter(|d| !d.is_empty())
}
pub(crate) fn library(name: &[u8], stem: &[u8]) -> bool {
    let Some(suffix) = name.strip_prefix(stem) else {
        return false;
    };
    suffix.is_empty()
        || suffix.strip_prefix(b".").is_some_and(|t| {
            t.split(|&c| c == b'.')
                .all(|x| !x.is_empty() && x.iter().all(u8::is_ascii_digit))
        })
}
fn companion(name: &[u8]) -> bool {
    [
        b"libnvidia-ptxjitcompiler.so".as_slice(),
        b"libnvidia-nvvm.so",
        b"libnvidia-nvvm70.so",
        b"libnvidia-gpucomp.so",
        b"libnvidia-tileiras.so",
        b"libnvcuextend.so",
        b"libcudadebugger.so",
    ]
    .iter()
    .any(|s| library(name, s))
}
pub fn directory(name: &CStr, addr: usize) -> Option<&'static [u8]> {
    let base = name.to_bytes().rsplit(|&c| c == b'/').next()?;
    if !library(base, b"libcuda.so") && !companion(base) {
        return None;
    }
    let id = mapped(addr)?;
    dirs().find(|d| join_path(&[d, b"/", base]).is_some_and(|n| same(n.as_c_str(), id)))
}
pub fn marker(name: &CStr, addr: usize) -> Option<CString> {
    // realpath writes at most PATH_MAX bytes to a caller-provided buffer.
    // Its successful result is NUL-terminated and borrows this allocation.
    let mut canonical = Vec::<c_char>::new();
    canonical.try_reserve_exact(PATH_MAX).ok()?;
    let result =
        core::ptr::NonNull::new(unsafe { libc::realpath(name.as_ptr(), canonical.as_mut_ptr()) })?;
    let name = unsafe { CStr::from_ptr(result.as_ptr()) };
    let index = join_path(&[
        policy::output(name.to_bytes())?,
        b"/nix-support/cuda-driver-selection",
    ])?;
    (io::marker(index.as_c_str()) && same(name, mapped(addr)?)).then_some(index)
}
fn host_file(path: &CStr) -> bool {
    let Some(fd) = io::open(path, OFlags::empty(), io::REG) else {
        return false;
    };
    let mut h = [0u8; 64];
    #[cfg(target_arch = "x86_64")]
    const MACHINE: u16 = libc::EM_X86_64;
    #[cfg(target_arch = "aarch64")]
    const MACHINE: u16 = libc::EM_AARCH64;
    rustix::io::retry_on_intr(|| rustix::io::read(&fd, &mut h)).ok() == Some(h.len())
        && h[..6] == *b"\x7fELF\x02\x01"
        && h[16..18] == libc::ET_DYN.to_le_bytes()
        && h[18..20] == MACHINE.to_le_bytes()
}
pub fn fallback(
    name: &CStr,
    caller: Option<&[u8]>,
    marked: impl FnOnce() -> bool,
) -> Option<CString> {
    // Nix glibc lacks the distribution paths. Only its final default search
    // may be supplemented, after the caller, environment, cache and hwcaps.
    let base = name
        .to_bytes()
        .strip_prefix(concat!(env!("NIX_CUDA_LAST_DEFAULT"), "/").as_bytes())?;
    let driver = base == b"libcuda.so.1";
    if driver {
        if !marked() {
            return None;
        }
    } else if caller.is_none() || !companion(base) {
        return None;
    }
    if io::exists(name) {
        return None;
    }
    let valid = |dir: &[u8]| {
        let name = join_path(&[dir, b"/", base])?;
        host_file(name.as_c_str()).then_some(name)
    };
    if driver {
        dirs().find_map(valid)
    } else {
        valid(caller?)
    }
}
