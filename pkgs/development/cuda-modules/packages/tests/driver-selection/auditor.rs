#![no_std]
mod panic;

#[unsafe(no_mangle)]
pub extern "C" fn la_version(version: u32) -> u32 {
    if cfg!(retain_paths) && version < 2 {
        0
    } else {
        version
    }
}

#[cfg(retain_paths)]
mod retain {
    use core::ffi::{CStr, c_char};

    // glibc serializes these search callbacks. Keep its original pointer so
    // later requests and object unloads exercise the returned name's lifetime.
    static mut FIRST: *const c_char = core::ptr::null();
    static mut SNAPSHOT: *const c_char = core::ptr::null();
    static mut REDIRECTS: usize = 0;

    unsafe extern "C" {
        fn strdup(s: *const c_char) -> *mut c_char;
    }

    unsafe fn unchanged() -> bool {
        unsafe { !SNAPSHOT.is_null() && CStr::from_ptr(FIRST) == CStr::from_ptr(SNAPSHOT) }
    }

    #[unsafe(no_mangle)]
    pub unsafe extern "C" fn la_objsearch(
        name: *const c_char,
        _: *mut usize,
        flag: u32,
    ) -> *const c_char {
        const LA_SER_ORIG: u32 = 1;
        if flag != LA_SER_ORIG {
            return name;
        }
        let request = unsafe { CStr::from_ptr(name) };
        let driver = b"/compat/libcuda.so.";
        if request
            .to_bytes()
            .windows(driver.len())
            .any(|prefix| prefix == driver)
        {
            unsafe {
                if FIRST.is_null() {
                    FIRST = name;
                    SNAPSHOT = strdup(name);
                }
                if !unchanged() {
                    return core::ptr::null();
                }
                REDIRECTS += 1;
            }
        }
        if request == c"verify-retained-audit-path.so" {
            return if unsafe { REDIRECTS == 2 && unchanged() } {
                c"libc.so.6".as_ptr()
            } else {
                core::ptr::null()
            };
        }
        name
    }
}
