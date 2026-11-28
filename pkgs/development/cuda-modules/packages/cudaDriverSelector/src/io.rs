#![forbid(unsafe_code)]
use alloc::vec::Vec;
use core::ffi::CStr;
use rustix::{
    fd::{AsFd, OwnedFd},
    fs::{self, Access, AtFlags, CWD, FileType, Mode, OFlags, StatxFlags},
    io::{self, Errno},
};

pub const REG: FileType = FileType::RegularFile;
pub fn kind(fd: impl AsFd, path: &CStr, flags: AtFlags, want: FileType) -> bool {
    let st = if path.is_empty() {
        fs::fstat(&fd)
    } else {
        fs::statat(&fd, path, flags)
    };
    match st {
        Ok(m) => FileType::from_raw_mode(m.st_mode) == want,
        // A container may permit just one of the two Linux metadata interfaces.
        Err(Errno::NOSYS | Errno::PERM | Errno::ACCESS) => {
            fs::statx(fd, path, flags, StatxFlags::TYPE).is_ok_and(|s| {
                s.stx_mask & StatxFlags::TYPE.bits() != 0
                    && FileType::from_raw_mode(s.stx_mode.into()) == want
            })
        }
        _ => false,
    }
}
pub fn open(path: &CStr, flags: OFlags, want: FileType) -> Option<OwnedFd> {
    let fd = fs::open(
        path,
        OFlags::RDONLY | OFlags::CLOEXEC | OFlags::NONBLOCK | OFlags::NOCTTY | flags,
        Mode::empty(),
    )
    .ok()?;
    kind(&fd, c"", AtFlags::EMPTY_PATH, want).then_some(fd)
}
pub fn exists(path: &CStr) -> bool {
    fs::access(path, Access::EXISTS).is_ok()
}
pub fn text(path: &CStr, limit: usize) -> Option<Vec<u8>> {
    let fd = open(path, OFlags::NOFOLLOW, REG)?;
    let mut buf = Vec::new();
    buf.try_reserve_exact(limit).ok()?;
    while buf.len() < limit {
        let n =
            io::retry_on_intr(|| io::read(&fd, rustix::buffer::spare_capacity(&mut buf))).ok()?;
        if n == 0 {
            return (!buf.is_empty() && !buf.contains(&0)).then_some(buf);
        }
    }
    None
}
// Visit LF-terminated records without collecting the whole file. Indexes must
// supply a whole pathname; proc maps needs only each record's numeric prefix.
pub fn lines<T>(
    fd: OwnedFd,
    limit: usize,
    accept_prefix: bool,
    mut visit: impl FnMut(&[u8]) -> Option<T>,
) -> Option<T> {
    let mut chunk = [0u8; 512];
    let mut line = Vec::new();
    line.try_reserve_exact(limit).ok()?;
    let mut too_long = false;
    loop {
        let n = io::retry_on_intr(|| io::read(&fd, &mut chunk)).ok()?;
        if n == 0 {
            return None;
        }
        for &ch in &chunk[..n] {
            if ch == b'\n' {
                if (!too_long || accept_prefix)
                    && !line.contains(&0)
                    && let Some(v) = visit(&line)
                {
                    return Some(v);
                }
                line.clear();
                too_long = false;
            } else if line.len() < limit {
                line.push(ch);
            } else {
                too_long = true;
            }
        }
    }
}

macro_rules! host_path {
    ($suffix:literal) => {
        CStr::from_bytes_with_nul(concat!(env!("NIX_CUDA_HOST_ROOT"), $suffix, "\0").as_bytes())
            .unwrap()
    };
}
pub fn kernel() -> Option<[u32; 3]> {
    // Orin's integrated compute driver needs its own compatibility package.
    #[cfg(target_arch = "aarch64")]
    if exists(host_path!("/dev/nvgpu")) || exists(host_path!("/sys/module/nvgpu")) {
        return None;
    }
    open(
        host_path!("/dev/nvidiactl"),
        OFlags::empty(),
        FileType::CharacterDevice,
    )?;
    let t = text(host_path!("/sys/module/nvidia/version"), 64)?;
    super::policy::version(t.strip_suffix(b"\n").unwrap_or(&t), false)
}
pub fn marker(path: &CStr) -> bool {
    kind(CWD, path, AtFlags::SYMLINK_NOFOLLOW, REG)
}
