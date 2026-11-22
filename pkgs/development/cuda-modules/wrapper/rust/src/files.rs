use std::ffi::{CStr, OsStr};
use std::fs::{self, File, Metadata, OpenOptions};
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, IntoRawFd};
use std::os::unix::fs::{FileExt, MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

pub fn descriptor_path(file: &File) -> Vec<u8> {
    format!("/proc/self/fd/{}", file.as_raw_fd()).into_bytes()
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
    let mut file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NONBLOCK)
        .open(path)?;
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

pub trait Artifact {
    fn size(&self) -> u64;
    fn read(&self, offset: u64, count: u64) -> io::Result<Vec<u8>>;
    fn write(&mut self, offset: u64, bytes: &[u8]) -> io::Result<()>;
}

fn check_range(size: u64, offset: u64, count: u64) -> io::Result<()> {
    if offset > size || count > size - offset {
        return Err(io::Error::other("byte range exceeds the artifact"));
    }
    Ok(())
}

// The library also supports buffers returned by in-process CUDA APIs.
impl Artifact for [u8] {
    fn size(&self) -> u64 {
        self.len() as u64
    }

    fn read(&self, offset: u64, count: u64) -> io::Result<Vec<u8>> {
        check_range(self.size(), offset, count)?;
        Ok(self[offset as usize..(offset + count) as usize].to_vec())
    }

    fn write(&mut self, offset: u64, bytes: &[u8]) -> io::Result<()> {
        check_range(self.size(), offset, bytes.len() as u64)?;
        let offset = offset as usize;
        self[offset..offset + bytes.len()].copy_from_slice(bytes);
        Ok(())
    }
}

pub struct Contents {
    file: File,
    size: u64,
}

impl Artifact for Contents {
    fn size(&self) -> u64 {
        self.size
    }

    fn read(&self, offset: u64, count: u64) -> io::Result<Vec<u8>> {
        check_range(self.size, offset, count)?;
        let mut bytes = vec![0; count as usize];
        self.file.read_exact_at(&mut bytes, offset)?;
        Ok(bytes)
    }

    fn write(&mut self, offset: u64, bytes: &[u8]) -> io::Result<()> {
        check_range(self.size, offset, bytes.len() as u64)?;
        self.file.write_all_at(bytes, offset)
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

    pub fn edit(
        self,
        tool: &str,
        update: impl FnOnce(&mut Contents) -> io::Result<()>,
    ) -> io::Result<()> {
        let path = &self.path;
        let after = fs::metadata(path)
            .ok()
            .filter(|info| info.is_file())
            .filter(|info| {
                !self
                    .before
                    .as_ref()
                    .is_some_and(|before| same_version(before, info))
            })
            .ok_or_else(|| io::Error::other(format!("{tool} didn't write {}", path.display())))?;
        let mut opened_output = false;
        let result = (|| {
            let file = OpenOptions::new()
                .read(true)
                .write(true)
                .custom_flags(libc::O_NONBLOCK)
                .open(path)?;
            let info = file.metadata()?;
            if !info.is_file() || !same_version(&after, &info) {
                return Err(io::Error::other(format!(
                    "{path:?} changed before it could be opened"
                )));
            }
            opened_output = true;
            let mut contents = Contents {
                file,
                size: info.len(),
            };
            update(&mut contents)?;
            // SAFETY: into_raw_fd consumes the sole owner, and Linux closes
            // the descriptor even if close reports EINTR.
            if unsafe { libc::close(contents.file.into_raw_fd()) } < 0 {
                let error = io::Error::last_os_error();
                if error.kind() != io::ErrorKind::Interrupted {
                    return Err(error);
                }
            }
            Ok(())
        })();
        if let Err(error) = result {
            if fs::metadata(path).is_ok_and(|current| {
                if opened_output {
                    same_file(&after, &current)
                } else {
                    same_version(&after, &current)
                }
            }) {
                let _ = fs::remove_file(path);
            }
            return Err(error);
        }
        Ok(())
    }

    pub fn rewrite_text(
        self,
        tool: &str,
        rewrite: impl FnOnce(&[u8]) -> Option<Vec<u8>>,
    ) -> io::Result<()> {
        self.edit(tool, |artifact| {
            if let Some(bytes) = rewrite(&artifact.read(0, artifact.size())?) {
                artifact.file.write_all_at(&bytes, 0)?;
                if bytes.len() as u64 != artifact.size() {
                    artifact.file.set_len(bytes.len() as u64)?;
                }
            }
            Ok(())
        })
    }
}
