use core::{
    alloc::{GlobalAlloc, Layout},
    ptr,
};
// Use the eagerly bound allocator from the auditor's private glibc namespace.
struct LoaderAllocator;
#[global_allocator]
static ALLOCATOR: LoaderAllocator = LoaderAllocator;
unsafe impl GlobalAlloc for LoaderAllocator {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        if layout.align() > align_of::<usize>() {
            return ptr::null_mut();
        }
        unsafe { libc::malloc(layout.size()).cast() }
    }
    unsafe fn realloc(&self, old: *mut u8, _: Layout, size: usize) -> *mut u8 {
        unsafe { libc::realloc(old.cast(), size).cast() }
    }
    unsafe fn dealloc(&self, p: *mut u8, _: Layout) {
        unsafe { libc::free(p.cast()) }
    }
}

#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! {
    unsafe { libc::abort() }
}
