use baracuda_nvjitlink::{InputType, Linker};
use cuda_tool_wrapper::{path_prefix_map::PathPrefixMap, ptx::normalize_source_info};
use cudarc::nvrtc::{CompileOptions, compile_ptx_with_opts};
use std::{error::Error, fs};

fn main() -> Result<(), Box<dyn Error>> {
    let ptx = compile_ptx_with_opts(
        r#"extern "C" __global__ void fill(int *output) { *output = 42; }"#,
        CompileOptions {
            arch: Some("compute_80"),
            name: Some("/original/kernel.cu".into()),
            options: vec!["--generate-line-info".into(), "--frandom-seed=42".into()],
            ..Default::default()
        },
    )?;
    let paths = PathPrefixMap::parse(b"/virtual=/original")?;
    let bytes = normalize_source_info(ptx.as_bytes().ok_or("expected NVRTC PTX")?, &paths, true)?
        .ok_or("expected NVRTC to emit a .file directive")?;
    assert!(
        bytes
            .windows(b"/virtual/kernel.cu".len())
            .any(|s| s == b"/virtual/kernel.cu")
    );

    let mut linker = Linker::new(&["-arch=sm_80", "-lineinfo"])?;
    linker.add_data(InputType::Ptx, &bytes, "kernel.ptx")?;
    linker.complete()?;
    fs::write("kernel.ptx", bytes.strip_suffix(&[0]).unwrap_or(&bytes))?;
    fs::write("kernel.cubin", linker.linked_cubin()?)?;
    Ok(())
}
