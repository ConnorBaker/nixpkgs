// Each fixture is linked separately and uses a different subset of glibc's API.
#![allow(dead_code)]

use core::ffi::{c_char, c_int, c_void};

pub const NOW: c_int = 2;
pub const NOLOAD: c_int = 4;
pub const NEW_NAMESPACE: isize = -1;

#[link(name = "dl")]
unsafe extern "C" {
    #[cfg_attr(static_lookup, link_name = env!("CUDA_STATIC_LOOKUP_SYMBOL"))]
    #[cfg_attr(forwarded_lookup, link_name = "forward")]
    pub fn dlopen(name: *const c_char, flags: c_int) -> *mut c_void;
    pub fn dlmopen(namespace: isize, name: *const c_char, flags: c_int) -> *mut c_void;
    pub fn dlsym(handle: *mut c_void, name: *const c_char) -> *mut c_void;
    pub fn dlclose(handle: *mut c_void) -> c_int;
    pub fn dlerror() -> *const c_char;
}

pub unsafe fn fixture_id(handle: *mut c_void) -> Option<c_int> {
    let value = unsafe { dlsym(handle, c"fixture_id".as_ptr()) }.cast::<c_int>();
    unsafe { value.as_ref().copied() }
}

#[cfg(any(by_name, driver_note))]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn inspect(name: *const c_char, flags: c_int) -> c_int {
    let driver = unsafe { dlopen(name, flags) };
    if driver.is_null() {
        if flags & NOLOAD != 0 {
            return 0;
        }
        unsafe extern "C" {
            static stderr: *mut core::ffi::c_void;
            fn fprintf(stream: *mut core::ffi::c_void, format: *const c_char, ...) -> c_int;
        }
        unsafe { fprintf(stderr, c"dlopen(%s): %s\n".as_ptr(), name, dlerror()) };
        return -1;
    }
    unsafe { fixture_id(driver) }.unwrap_or(-1)
}
