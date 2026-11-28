#![no_std]
#![feature(explicit_tail_calls)]
#![allow(incomplete_features)]

use core::ffi::{CStr, c_char, c_int, c_void};
use core::ptr;

type Handle = *mut c_void;
const RTLD_NOLOAD: c_int = 4;

unsafe extern "C" {
    // The DSO must also load under glibc before 2.34, where dlopen lives in
    // libdl. The archive's undefined references bind at the consumer's link.
    #[cfg_attr(
        all(not(static_cudart), target_arch = "aarch64"),
        link_name = "dlopen@GLIBC_2.17"
    )]
    #[cfg_attr(
        all(not(static_cudart), target_arch = "x86_64"),
        link_name = "dlopen@GLIBC_2.2.5"
    )]
    fn dlopen(name: *const c_char, flags: c_int) -> Handle;
    fn __errno_location() -> *mut c_int;
}

#[unsafe(export_name = env!("CUDA_LOOKUP_SYMBOL"))]
pub unsafe extern "C" fn lookup(name: *const c_char, flags: c_int) -> Handle {
    if !name.is_null()
        && flags & RTLD_NOLOAD == 0
        && unsafe { CStr::from_ptr(name) } == c"libcuda.so.1"
    {
        let driver = unsafe { provider::try_driver(flags) };
        if !driver.is_null() {
            return driver;
        }
    }
    // glibc uses its caller's return address for the namespace, RUNPATH and $ORIGIN.
    unsafe { become dlopen(name, flags) }
}

#[cfg(not(static_cudart))]
mod provider {
    use super::*;

    unsafe extern "C" {
        fn nix_candidate_matches(manifest: *const c_char, expected: *const c_char) -> bool;
    }

    // dlsym on the helper supplies this entry to static CUDART. Bind lookup's
    // own call locally when another toolkit exports the same entry in the process.
    core::arch::global_asm!(".protected nix_cuda_try_driver");
    #[inline(never)]
    #[unsafe(export_name = "nix_cuda_try_driver")]
    pub(super) unsafe extern "C" fn try_driver(flags: c_int) -> Handle {
        let errno = unsafe { __errno_location() };
        let saved = unsafe { *errno };
        let eligible = unsafe {
            nix_candidate_matches(
                concat!(env!("CUDA_COMPAT_MANIFEST"), "\0").as_ptr().cast(),
                concat!(env!("CUDA_COMPAT_DRIVER"), "\0").as_ptr().cast(),
            )
        };
        unsafe { *errno = saved };
        if eligible {
            // Check for an existing SONAME and search our private RPATH under
            // glibc's loader lock. This call has to originate in the helper.
            let driver = unsafe { dlopen(c"libcuda.so.1".as_ptr(), flags) };
            if !driver.is_null() {
                return driver;
            }
            unsafe { *errno = saved };
        }
        ptr::null_mut()
    }

    #[unsafe(export_name = env!("CUDA_COMPANION_SYMBOL"))]
    pub unsafe extern "C" fn companion(mut name: *const c_char, flags: c_int) -> Handle {
        if !name.is_null() {
            let requested = unsafe { CStr::from_ptr(name) }.to_bytes_with_nul();
            let mut table: &[u8] = include_bytes!(env!("CUDA_COMPANIONS"));
            let mut next = || {
                let end = table.iter().position(|&byte| byte == 0)? + 1;
                let (field, rest) = table.split_at_checked(end)?;
                table = rest;
                Some(field)
            };
            while let (Some(alias), Some(path)) = (next(), next()) {
                if alias == requested {
                    name = path.as_ptr().cast();
                    break;
                }
            }
        }
        unsafe { become dlopen(name, flags) }
    }
}

#[cfg(static_cudart)]
mod provider {
    use super::*;

    // Only members of the same final ELF can bind this archive symbol.
    core::arch::global_asm!(concat!(".hidden ", env!("CUDA_LOOKUP_SYMBOL")));
    unsafe extern "C" {
        fn dlsym(module: Handle, name: *const c_char) -> *mut c_void;
        fn dlclose(module: Handle) -> c_int;
    }

    pub(super) unsafe fn try_driver(flags: c_int) -> Handle {
        let errno = unsafe { __errno_location() };
        let saved = unsafe { *errno };
        // A transient reference lets a foreign process use the static runtime
        // without acquiring a DT_NEEDED on our helper or its libc.
        const RTLD_NOW: c_int = 2;
        let module = unsafe {
            dlopen(
                concat!(env!("CUDA_LOOKUP_PATH"), "\0").as_ptr().cast(),
                RTLD_NOW,
            )
        };
        if !module.is_null() {
            let symbol = unsafe { dlsym(module, c"nix_cuda_try_driver".as_ptr()) };
            let mut driver = ptr::null_mut();
            if !symbol.is_null() {
                let attempt: unsafe extern "C" fn(c_int) -> Handle =
                    unsafe { core::mem::transmute(symbol) };
                driver = unsafe { attempt(flags) };
            }
            unsafe { dlclose(module) };
            if !driver.is_null() {
                return driver;
            }
        }
        unsafe { *errno = saved };
        ptr::null_mut()
    }
}
