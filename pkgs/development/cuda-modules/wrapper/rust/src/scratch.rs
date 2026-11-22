use crate::arguments::Argument;
use crate::files::{descriptor_path, same_file};
use std::fs::{self, DirBuilder, File, OpenOptions};
use std::io;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

pub fn stable_id(cwd: &Path, args: &[Argument]) -> String {
    // FNV-1a with NUL separators, matching the C++ wrapper.
    let mut hash = 14695981039346656037u64;
    for part in std::iter::once(cwd.as_os_str().as_bytes()).chain(args.iter().map(Vec::as_slice)) {
        for byte in part.iter().copied().chain([0]) {
            hash = (hash ^ u64::from(byte)).wrapping_mul(1099511628211);
        }
    }
    format!("{hash:016x}")
}

pub struct ScratchDirectory {
    path: PathBuf,
    lease: Option<File>,
}

const MARKER: &str = ".nix-cuda-wrapper";

fn open_directory(path: &Path) -> io::Result<File> {
    OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW)
        .open(path)
}

fn descriptor_directory(dir: &File) -> PathBuf {
    PathBuf::from(descriptor_path(dir))
}

impl ScratchDirectory {
    pub fn acquire(path: PathBuf) -> Option<Self> {
        // SAFETY: geteuid has no arguments or side effects.
        let uid = unsafe { libc::geteuid() };
        loop {
            match DirBuilder::new().mode(0o700).create(&path) {
                Ok(()) => {}
                Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
                Err(_) => return None,
            }
            let dir = match open_directory(&path) {
                Ok(dir) => dir,
                Err(error) if error.kind() == io::ErrorKind::NotFound => continue,
                Err(_) => return None,
            };
            let opened = dir.metadata().ok()?;
            if opened.uid() != uid || opened.mode() & 0o777 != 0o700 {
                return None;
            }
            dir.lock().ok()?;
            match fs::symlink_metadata(&path) {
                Ok(current) if same_file(&current, &opened) => {
                    Self::prepare(&descriptor_directory(&dir), uid)?;
                    return Some(Self {
                        path,
                        lease: Some(dir),
                    });
                }
                Ok(_) => {}
                Err(error) if error.kind() == io::ErrorKind::NotFound => {}
                Err(_) => return None,
            }
        }
    }

    fn prepare(dir: &Path, uid: u32) -> Option<()> {
        let marker = dir.join(MARKER);
        let mut entries = fs::read_dir(dir).ok()?;
        match marker.symlink_metadata() {
            Ok(info)
                if info.is_file() && info.uid() == uid && info.nlink() == 1 && info.len() == 0 =>
            {
                for entry in entries {
                    let entry = entry.ok()?;
                    if entry.file_name() != MARKER {
                        if entry.file_type().ok()?.is_dir() {
                            fs::remove_dir_all(entry.path()).ok()?;
                        } else {
                            fs::remove_file(entry.path()).ok()?;
                        }
                    }
                }
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound && entries.next().is_none() => {
                OpenOptions::new()
                    .write(true)
                    .mode(0o600)
                    .create_new(true)
                    .open(marker)
                    .ok()?;
            }
            _ => return None,
        }
        Some(())
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn lease(&self) -> Option<&File> {
        self.lease.as_ref()
    }
}

impl Drop for ScratchDirectory {
    fn drop(&mut self) {
        let Some(lease) = self.lease.take() else {
            return;
        };
        // A fresh open holds an independent lock. The vendor process tree
        // or a later invocation may still hold the original lease.
        let cleanup = open_directory(&descriptor_directory(&lease).join("."));
        drop(lease);
        let Ok(cleanup) = cleanup else { return };
        if cleanup.try_lock().is_err() {
            return;
        }
        if let (Ok(opened), Ok(current)) = (cleanup.metadata(), fs::symlink_metadata(&self.path))
            && same_file(&opened, &current)
            && let Err(error) = fs::remove_dir_all(&self.path)
        {
            eprintln!("nvcc wrapper: cannot remove {:?}: {error}", self.path);
        }
    }
}
