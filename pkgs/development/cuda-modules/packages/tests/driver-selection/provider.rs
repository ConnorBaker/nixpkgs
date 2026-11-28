#![no_std]

#[cfg(driver_note)]
mod dl;
mod panic;

use core::ffi::c_int;
const ID: c_int = match c_int::from_str_radix(env!("FIXTURE_ID"), 10) {
    Ok(id) => id,
    Err(_) => panic!("FIXTURE_ID must be an integer"),
};

#[cfg(driver_note)]
mod driver_note {
    const OWNER: &[u8; 19] = b"NVIDIA Corporation\0";
    const POLICY: &[u8] = concat!(
        "{\"format\":",
        env!("NOTE_FORMAT"),
        ",\"driver\":[",
        env!("DRIVER_BRANCHES"),
        "]}\0"
    )
    .as_bytes();

    // ELF aligns both the owner and the descriptor to four bytes.
    #[repr(C, align(4))]
    struct Aligned<const N: usize>([u8; N]);

    #[repr(C)]
    struct Note {
        namesz: u32,
        descsz: u32,
        kind: u32,
        name: Aligned<{ OWNER.len() }>,
        desc: Aligned<{ POLICY.len() }>,
    }

    #[used]
    #[unsafe(link_section = ".note.cuda.fwd_compatibility")]
    static NOTE: Note = Note {
        namesz: OWNER.len() as u32,
        descsz: POLICY.len() as u32,
        kind: 0,
        name: Aligned(*OWNER),
        desc: Aligned(*POLICY.as_array().unwrap()),
    };
}

#[unsafe(no_mangle)]
pub static mut fixture_id: c_int = ID;

#[cfg(driver_note)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cuDriverGetVersion(version: *mut c_int) -> c_int {
    unsafe { version.write(ID) };
    0
}

#[cfg(driver_note)]
#[unsafe(no_mangle)]
pub extern "C" fn cuInit(_: u32) -> c_int {
    // Loading a driver must leave initialization to the application.
    unsafe { panic::abort() }
}
