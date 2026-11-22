use std::ffi::{CStr, OsStr};
use std::fs::{self, File, Metadata, OpenOptions};
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, IntoRawFd};
use std::os::unix::fs::{FileExt, MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

pub fn descriptor_path(file: &File) -> String {
    format!("/proc/self/fd/{}", file.as_raw_fd())
}

// The vendor process needs access to the anonymous input after exec.
pub fn anonymous_input(name: &CStr, contents: &[u8]) -> io::Result<File> {
    // SAFETY: name is a valid NUL-terminated string.
    let descriptor = unsafe { libc::memfd_create(name.as_ptr(), 0) };
    if descriptor < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: memfd_create has just returned a new owned descriptor.
    let mut file = unsafe { File::from_raw_fd(descriptor) };
    file.write_all(contents)?;
    Ok(file)
}

pub fn same_file(a: &Metadata, b: &Metadata) -> bool {
    a.dev() == b.dev() && a.ino() == b.ino()
}

fn same_version(a: &Metadata, b: &Metadata) -> bool {
    same_file(a, b)
        && (a.mtime(), a.mtime_nsec(), a.ctime(), a.ctime_nsec())
            == (b.mtime(), b.mtime_nsec(), b.ctime(), b.ctime_nsec())
}

pub fn special_file(path: &Path) -> bool {
    fs::metadata(path).is_ok_and(|info| !info.is_file())
}

fn open(path: impl AsRef<Path>, write: bool) -> io::Result<File> {
    OpenOptions::new()
        .read(true)
        .write(write)
        .custom_flags(libc::O_NONBLOCK)
        .open(path)
}

pub fn read_regular(path: &OsStr, remaining: &mut usize) -> io::Result<Vec<u8>> {
    let not_regular = || {
        io::Error::other(format!(
            "options file {} is missing or not a regular file",
            path.to_string_lossy()
        ))
    };
    if !fs::metadata(path).is_ok_and(|info| info.is_file()) {
        return Err(not_regular());
    }
    // A FIFO swapped in after metadata() must not make inspection block.
    let mut file = open(path, false)?;
    let info = file.metadata()?;
    if !info.is_file() {
        return Err(not_regular());
    }
    let size = usize::try_from(info.len())
        .ok()
        .filter(|&size| size <= *remaining)
        .ok_or_else(|| io::Error::other("input exceeds the inspection size limit"))?;
    let mut bytes = vec![0; size];
    file.read_exact(&mut bytes)?;
    *remaining -= size;
    Ok(bytes)
}

pub enum Artifact<'a> {
    Bytes(&'a mut [u8]),
    File { file: &'a File, size: u64 },
}

impl Artifact<'_> {
    pub fn size(&self) -> u64 {
        match self {
            Self::Bytes(bytes) => bytes.len() as u64,
            Self::File { size, .. } => *size,
        }
    }

    fn range(&self, start: u64, count: u64) -> io::Result<std::ops::Range<usize>> {
        let size = self.size();
        if start > size || count > size - start {
            return Err(io::Error::other("byte range exceeds the artifact"));
        }
        Ok(start as usize..(start + count) as usize)
    }

    pub fn read(&self, offset: u64, count: u64) -> io::Result<Vec<u8>> {
        let range = self.range(offset, count)?;
        match self {
            Self::Bytes(bytes) => Ok(bytes[range].to_vec()),
            Self::File { file, .. } => {
                let mut bytes = vec![0; range.len()];
                file.read_exact_at(&mut bytes, offset)?;
                Ok(bytes)
            }
        }
    }

    pub fn write(&mut self, offset: u64, bytes: &[u8]) -> io::Result<()> {
        let range = self.range(offset, bytes.len() as u64)?;
        match self {
            Self::Bytes(output) => output[range].copy_from_slice(bytes),
            Self::File { file, .. } => return file.write_all_at(bytes, offset),
        }
        Ok(())
    }
}

pub struct GeneratedFile {
    path: PathBuf,
    before: Option<Metadata>,
}

impl GeneratedFile {
    pub fn new(path: PathBuf) -> io::Result<Self> {
        let before = fs::metadata(&path).ok();
        if before.as_ref().is_some_and(|info| !info.is_file()) {
            return Err(io::Error::other(format!(
                "{} is not a regular file",
                path.display()
            )));
        }
        Ok(Self { path, before })
    }

    fn edit_file(
        self,
        tool: &str,
        update: impl FnOnce(&File, u64) -> io::Result<()>,
    ) -> io::Result<()> {
        let path = &self.path;
        let after = match path.metadata() {
            Ok(info)
                if info.is_file()
                    && self
                        .before
                        .as_ref()
                        .is_none_or(|before| !same_version(before, &info)) =>
            {
                info
            }
            _ => {
                return Err(io::Error::other(format!(
                    "{tool} didn't write {}",
                    path.display()
                )));
            }
        };
        let mut verified = false;
        let result = (|| {
            let file = open(path, true)?;
            let info = file.metadata()?;
            if !info.is_file() || !same_version(&after, &info) {
                return Err(io::Error::other(format!(
                    "{path:?} changed before it could be opened"
                )));
            }
            verified = true;
            update(&file, after.len())?;
            // SAFETY: into_raw_fd consumes the sole owner, and Linux closes
            // the descriptor even if close reports EINTR.
            if unsafe { libc::close(file.into_raw_fd()) } < 0 {
                let error = io::Error::last_os_error();
                if error.kind() != io::ErrorKind::Interrupted {
                    return Err(error);
                }
            }
            Ok(())
        })();

        if result.is_err()
            && path.metadata().is_ok_and(|current| {
                if verified {
                    same_file(&after, &current)
                } else {
                    same_version(&after, &current)
                }
            })
        {
            let _ = fs::remove_file(path);
        }
        result
    }

    pub fn edit(
        self,
        tool: &str,
        update: impl FnOnce(&mut Artifact<'_>) -> io::Result<()>,
    ) -> io::Result<()> {
        self.edit_file(tool, |file, size| {
            update(&mut Artifact::File { file, size })
        })
    }

    pub fn rewrite_text(
        self,
        tool: &str,
        rewrite: impl FnOnce(&[u8]) -> Option<Vec<u8>>,
    ) -> io::Result<()> {
        self.edit_file(tool, |file, size| {
            if let Some(bytes) = rewrite(&Artifact::File { file, size }.read(0, size)?) {
                file.write_all_at(&bytes, 0)?;
                if bytes.len() as u64 != size {
                    file.set_len(bytes.len() as u64)?;
                }
            }
            Ok(())
        })
    }
}
