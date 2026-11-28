#![no_std]
#![deny(unsafe_op_in_unsafe_fn)]
extern crate alloc;
use alloc::{ffi::CString, vec::Vec};
use core::{
    cell::UnsafeCell,
    cmp::Reverse,
    ffi::{CStr, c_char},
    sync::atomic::{AtomicU8, Ordering},
};
use rustix::fs::OFlags;
#[cfg(not(test))]
mod allocator;
mod host;
mod io;
mod policy;
#[cfg(test)]
mod tests;

// glibc <link.h>. ABI 1 loaders can crash during dlmopen even with no-op
// audit callbacks. The private lookup helper works independently of auditing.
const AUDIT_VERSION: u32 = 2;
const LA_SER_ORIG: u32 = 1;
const LA_SER_DEFAULT: u32 = 64;
const PATH_MAX: usize = libc::PATH_MAX as usize;

// Bound the complete Linux pathname and preserve ordinary lookup on ENOMEM.
fn join_path(parts: &[&[u8]]) -> Option<CString> {
    let len = parts
        .iter()
        .try_fold(1usize, |n, part| n.checked_add(part.len()))?;
    if len > PATH_MAX {
        return None;
    }
    let mut bytes = Vec::new();
    bytes.try_reserve_exact(len).ok()?;
    for part in parts {
        bytes.extend_from_slice(part);
    }
    bytes.push(0);
    // CString boxes the buffer. Excess capacity would require an infallible shrink.
    (bytes.capacity() == len).then_some(())?;
    CString::from_vec_with_nul(bytes).ok()
}

struct Entry {
    ns: usize,
    host: Option<&'static [u8]>,
    index: Option<CString>,
    users: usize,
}
struct State {
    entries: Vec<Option<Entry>>,
    names: Vec<CString>,
}
impl State {
    const EMPTY: Self = Self {
        entries: Vec::new(),
        names: Vec::new(),
    };

    // Odd cookies encode an unmarked namespace; even cookies index live slots.
    // Vec growth may move entries, so the loader never receives their addresses.
    fn register(
        &mut self,
        ns: usize,
        host: Option<&'static [u8]>,
        index: Option<CString>,
    ) -> Option<usize> {
        for (i, slot) in self.entries.iter_mut().enumerate() {
            if let Some(entry) = slot
                && (entry.ns, entry.host, entry.index.as_deref()) == (ns, host, index.as_deref())
            {
                entry.users = entry.users.checked_add(1)?;
                return Some((i + 1) * 2);
            }
        }
        let i = match self.entries.iter().position(Option::is_none) {
            Some(i) => i,
            None => {
                self.entries.try_reserve(1).ok()?;
                self.entries.push(None);
                self.entries.len() - 1
            }
        };
        self.entries[i] = Some(Entry {
            ns,
            host,
            index,
            users: 1,
        });
        Some((i + 1) * 2)
    }
    fn close(&mut self, cookie: usize) {
        if cookie == 0 || cookie & 1 != 0 {
            return;
        }
        let Some(slot) = self.entries.get_mut(cookie / 2 - 1) else {
            return;
        };
        if let Some(entry) = slot {
            entry.users -= 1;
            if entry.users == 0 {
                *slot = None;
                while self.entries.last().is_some_and(Option::is_none) {
                    self.entries.pop();
                }
                if self.entries.is_empty() {
                    self.entries = Vec::new();
                }
            }
        }
    }
    // Other auditors may retain returned names after the associated maps close.
    // Moving the Vec handles leaves their owned byte allocations in place.
    fn keep(&mut self, name: CString) -> Option<*const c_char> {
        if let Some(saved) = self.names.iter().find(|p| **p == name) {
            return Some(saved.as_ptr());
        }
        self.names.try_reserve(1).ok()?;
        let p = name.as_ptr();
        self.names.push(name);
        Some(p)
    }
    fn select(&self, cookie: usize, name: &CStr, stage: u32) -> Option<CString> {
        let caller = (cookie & 1 == 0)
            .then(|| self.entries.get(cookie / 2 - 1)?.as_ref())
            .flatten();
        let ns = caller.map_or(cookie >> 1, |e| e.ns);
        let mut indexes = self
            .entries
            .iter()
            .flatten()
            .filter(|e| e.ns == ns)
            .filter_map(|e| e.index.as_deref())
            .peekable();
        if stage == LA_SER_DEFAULT {
            return host::fallback(name, caller.and_then(|e| e.host), || {
                indexes.next().is_some()
            });
        }
        indexes.peek()?;
        let kernel = io::kernel()?;
        let mut best = None;
        for index in indexes {
            if let Some(fd) = io::open(index, OFlags::NOFOLLOW, io::REG) {
                io::lines::<()>(fd, PATH_MAX - 1, false, |line| {
                    let next = join_path(&[line]).and_then(|m| candidate(m.as_c_str(), kernel));
                    best = best.take().max(next);
                    None
                });
            }
        }
        best.map(|(_, Reverse(name))| name)
    }
}
// Prefer the newest eligible driver; equal versions pick the lexically first
// path independently of registration or index order.
fn candidate(manifest: &CStr, kernel: [u32; 3]) -> Option<([u32; 3], Reverse<CString>)> {
    let root = policy::output(manifest.to_bytes())?;
    if manifest.to_bytes().strip_prefix(root)? != b"/nix-support/nix-cuda-compat" {
        return None;
    }
    let text = io::text(manifest, PATH_MAX + 512)?;
    let (version, path) = policy::eligible(root, &text, kernel)?;
    let path = join_path(&[path])?;
    io::open(path.as_c_str(), OFlags::NOFOLLOW, io::REG)?;
    Some((version, Reverse(path)))
}

struct Global {
    access: AtomicU8,
    state: UnsafeCell<State>,
}

impl Global {
    const fn new() -> Self {
        Self {
            access: AtomicU8::new(0),
            state: UnsafeCell::new(State::EMPTY),
        }
    }

    // Normal loads hold glibc's load lock. Process-exit la_objclose can run
    // outside it. Never wait in a loader callback, including if fork copied a
    // busy registry. Missing an event disables policy for subsequent callbacks;
    // previously returned names remain allocated for the life of the process.
    fn with<T>(&self, f: impl FnOnce(&mut State) -> Option<T>) -> Option<T> {
        const IDLE: u8 = 0;
        const BUSY: u8 = 1;
        const DISABLED: u8 = 2;
        let previous = self
            .access
            .try_update(Ordering::Acquire, Ordering::Relaxed, |state| match state {
                IDLE => Some(BUSY),
                BUSY => Some(DISABLED),
                _ => None,
            });
        if previous != Ok(IDLE) {
            return None;
        }
        // Only the successful IDLE -> BUSY transition grants a reference.
        let result = f(unsafe { &mut *self.state.get() });
        self.access
            .compare_exchange(BUSY, IDLE, Ordering::Release, Ordering::Relaxed)
            .ok()?;
        result
    }
}

// All access goes through with(); its callback cannot return a state borrow.
unsafe impl Sync for Global {}
static STATE: Global = Global::new();

#[repr(C)]
// Public prefix of glibc struct link_map on the two 64-bit CUDA platforms.
pub struct Map {
    addr: usize,
    name: *const c_char,
    dynamic: *const core::ffi::c_void,
}
#[unsafe(no_mangle)]
pub extern "C" fn la_version(v: u32) -> u32 {
    if v >= AUDIT_VERSION && unsafe { libc::getauxval(libc::AT_SECURE) } == 0 {
        AUDIT_VERSION
    } else {
        0
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn la_objopen(map: *const Map, ns: usize, cookie: *mut usize) -> u32 {
    STATE.with(|state| {
        // glibc supplies a live map and NUL-terminated name for this callback.
        let map = unsafe { &*map };
        let name = unsafe { CStr::from_ptr(map.name) };
        let address = map.dynamic.addr();
        let host = host::directory(name, address);
        let executable = if name.is_empty() {
            // AT_EXECFN identifies the program even when invoking ld.so directly.
            let p = unsafe { libc::getauxval(libc::AT_EXECFN) } as *const c_char;
            let path = (!p.is_null()).then(|| unsafe { CStr::from_ptr(p) });
            path.filter(|s| !s.is_empty()).unwrap_or(c"/proc/self/exe")
        } else {
            name
        };
        let index = host::marker(executable, address);
        let registered = match (host, index) {
            (None, None) => None,
            (host, index) => state.register(ns, host, index),
        };
        unsafe { cookie.write(registered.unwrap_or((ns << 1) | 1)) };
        Some(())
    });
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn la_objclose(cookie: *mut usize) -> u32 {
    STATE.with(|state| {
        // Clear the cookie under the same guard before its slot can be reused.
        state.close(unsafe { cookie.replace(0) });
        Some(())
    });
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn la_objsearch(
    name: *const c_char,
    cookie: *const usize,
    stage: u32,
) -> *const c_char {
    if !matches!(stage, LA_SER_ORIG | LA_SER_DEFAULT) {
        return name;
    }
    let requested = unsafe { CStr::from_ptr(name) };
    if stage == LA_SER_ORIG && requested != c"libcuda.so.1" {
        return name;
    }
    STATE
        .with(|state| {
            let cookie = unsafe { cookie.read() };
            if cookie == 0 {
                return None;
            }
            let selected = state.select(cookie, requested, stage)?;
            state.keep(selected)
        })
        .unwrap_or(name)
}

// The late vendor-runtime helper reuses the auditor's policy and file checks.
// The private symbol is omitted from the auditor's export map.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nix_candidate_matches(
    manifest: *const c_char,
    expected: *const c_char,
) -> bool {
    let Some(kernel) = io::kernel() else {
        return false;
    };
    let manifest = unsafe { CStr::from_ptr(manifest) };
    let expected = unsafe { CStr::from_ptr(expected) };
    candidate(manifest, kernel).is_some_and(|(_, Reverse(name))| name.as_c_str() == expected)
}
