#![no_std]
#![feature(explicit_tail_calls)]
#![allow(incomplete_features)]
mod dl;

use core::ffi::{c_char, c_int, c_void};

// The extension must see the original requester's return address.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn forward(name: *const c_char, flags: c_int) -> *mut c_void {
    unsafe { become dl::dlopen(name, flags) }
}
