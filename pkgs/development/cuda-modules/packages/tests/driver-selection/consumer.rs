#![cfg_attr(not(any(executable, downstream)), no_std)]

#[cfg(by_name)]
mod dl;
#[cfg(not(any(executable, downstream)))]
mod panic;

#[cfg(not(any(empty, by_name)))]
use core::ffi::{c_char, c_int};

#[cfg(not(any(by_name, downstream, empty)))]
#[unsafe(no_mangle)]
pub extern "C" fn inspect(_: *const c_char, _: c_int) -> c_int {
    unsafe extern "C" {
        fn cuDriverGetVersion(version: *mut c_int) -> c_int;
        static fixture_id: c_int;
    }
    let mut version = 0;
    if unsafe { cuDriverGetVersion(&mut version) == 0 && version == fixture_id } {
        version
    } else {
        -1
    }
}

#[cfg(executable)]
fn main() {
    println!("{}", inspect(core::ptr::null(), 0));
}

#[cfg(downstream)]
fn main() {
    unsafe extern "C" {
        fn inspect(name: *const c_char, flags: c_int) -> c_int;
    }
    std::process::exit(unsafe { inspect(c"libcuda.so.1".as_ptr(), 2) });
}
