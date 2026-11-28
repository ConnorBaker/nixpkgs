#![no_std]
#![feature(explicit_tail_calls, link_llvm_intrinsics)]
#![allow(incomplete_features, internal_features)]

use core::ffi::{c_char, c_int, c_void};
use core::mem::MaybeUninit;

type Handle = *mut c_void;
const RTLD_NOLOAD: c_int = 4;
const HOST_ANCHOR: &[u8] = concat!(env!("CUDA_BINDINGS_HOST_ANCHOR"), "\0").as_bytes();

#[repr(C)]
struct DlInfo {
    filename: *const c_char,
    base: *const c_void,
    symbol: *const c_char,
    address: *const c_void,
}

unsafe extern "C" {
    fn __real_dlopen(name: *const c_char, flags: c_int) -> Handle;
    #[link_name = env!("CUDA_BINDINGS_LOOKUP")]
    fn lookup(name: *const c_char, flags: c_int) -> Handle;
    fn strcmp(left: *const c_char, right: *const c_char) -> c_int;
    fn dladdr(address: *const c_void, info: *mut DlInfo) -> c_int;
    fn dlclose(handle: Handle) -> c_int;
    #[link_name = "llvm.returnaddress"]
    fn return_address(level: i32) -> *const c_void;
}

unsafe fn image(address: *const c_void) -> Option<*const c_void> {
    let mut info = MaybeUninit::<DlInfo>::uninit();
    unsafe { (dladdr(address, info.as_mut_ptr()) != 0).then(|| (*info.as_ptr()).base) }
}

// Each extension must bind references to its own copy of the wrapper.
core::arch::global_asm!(".hidden __wrap_dlopen");

#[unsafe(no_mangle)]
unsafe extern "C" fn __wrap_dlopen(name: *const c_char, flags: c_int) -> Handle {
    unsafe {
        if name.is_null() || flags & RTLD_NOLOAD != 0 || strcmp(name, c"libcuda.so.1".as_ptr()) != 0
        {
            become __real_dlopen(name, flags);
        }
        // An upstream tail call can leave the return address in another DSO.
        // Only an extension's own driver requests get its host-directory retry.
        let caller = image(return_address(0));
        if caller.is_none() || caller != image(__wrap_dlopen as *const c_void) {
            become lookup(name, flags);
        }
        let mut driver = lookup(name, flags);
        if driver.is_null() {
            let anchor = __real_dlopen(HOST_ANCHOR.as_ptr().cast(), flags);
            if !anchor.is_null() {
                driver = __real_dlopen(name, flags);
                dlclose(anchor);
            }
        }
        driver
    }
}
