mod dl;

use std::env;
use std::ffi::{CStr, CString, c_char, c_int};
use std::os::unix::ffi::OsStrExt;

// Each open handle remains in its namespace until an explicit close action.
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut args = env::args_os().skip(1);
    while let Some(action) = args.next() {
        let path = args.next().ok_or("missing library path")?;
        let action = action.to_str().ok_or("invalid action")?;
        if action == "chdir" {
            env::set_current_dir(path)?;
            continue;
        }
        let path = CString::new(path.as_bytes())?;
        if action == "absent" {
            if !unsafe { dl::dlopen(path.as_ptr(), dl::NOLOAD | dl::NOW) }.is_null() {
                return Err(format!("{path:?} was already loaded").into());
            }
            continue;
        }

        let handle = if action == "separate" {
            unsafe { dl::dlmopen(dl::NEW_NAMESPACE, path.as_ptr(), dl::NOW) }
        } else {
            unsafe { dl::dlopen(path.as_ptr(), dl::NOW) }
        };
        if handle.is_null() {
            let error = unsafe { CStr::from_ptr(dl::dlerror()) };
            return Err(format!("{path:?}: {}", error.to_string_lossy()).into());
        }
        match action {
            "open" | "separate" => (),
            "close" if unsafe { dl::dlclose(handle) } == 0 => (),
            "close" => return Err(format!("could not close {path:?}").into()),
            "call" | "noload" => {
                let name = args.next().ok_or("missing driver name")?;
                let name = CString::new(name.as_bytes())?;
                let address = unsafe { dl::dlsym(handle, c"inspect".as_ptr()) };
                if address.is_null() {
                    return Err(format!("{path:?} does not export inspect").into());
                }
                let inspect: unsafe extern "C" fn(*const c_char, c_int) -> c_int =
                    unsafe { std::mem::transmute(address) };
                let flags = if action == "noload" {
                    dl::NOW | dl::NOLOAD
                } else {
                    dl::NOW
                };
                println!("{}", unsafe { inspect(name.as_ptr(), flags) });
            }
            _ => return Err(format!("unknown probe action {action}").into()),
        }
    }
    Ok(())
}
