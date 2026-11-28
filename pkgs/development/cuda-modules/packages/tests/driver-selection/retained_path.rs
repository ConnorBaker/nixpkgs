mod dl;

use std::ffi::CString;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let path = std::env::args_os().nth(1).ok_or("missing requester")?;
    let path = CString::new(path.as_encoded_bytes())?;
    let requester = unsafe { dl::dlopen(path.as_ptr(), dl::NOW) };
    assert!(!requester.is_null());
    for (kernel, expected) in [("615.1", 620), ("610.1", 619)] {
        std::fs::write("sys/module/nvidia/version", kernel)?;
        let driver = unsafe { dl::dlopen(c"libcuda.so.1".as_ptr(), dl::NOW) };
        assert!(!driver.is_null());
        assert_eq!(unsafe { dl::fixture_id(driver) }, Some(expected));
        assert_eq!(unsafe { dl::dlclose(driver) }, 0);
    }
    assert_eq!(unsafe { dl::dlclose(requester) }, 0);
    assert!(!unsafe { dl::dlopen(c"verify-retained-audit-path.so".as_ptr(), dl::NOW) }.is_null());
    Ok(())
}
