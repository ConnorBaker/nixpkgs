use crate::arguments::{Quote, tokenize};
use crate::artifact::{blank_store_hashes, edit_elf_sections};
use crate::ptx::{PathPrefixMap, normalize_source_info};

#[test]
fn nvidia_option_quoting_preserves_raw_path_bytes() {
    let options = b"-o \"output \xff\" \t \"escaped\\\"quote\" \"\"";
    let words = tokenize(options, Quote::Preserve).unwrap();
    assert_eq!(
        words,
        [b"-o".as_slice(), b"output \xff", b"escaped\"quote", b""]
    );
    let words = tokenize(options, Quote::Discard).unwrap();
    assert_eq!(words[2], b"escapedquote");
}

#[test]
fn ptx_only_rewrites_file_directives() {
    let paths = PathPrefixMap::parse(b"/canonical=/root:/override=/root").unwrap();
    let source = b".version 8.0\n/* .file 1 \"/root/ignored\" */\n.file 2 \"/root/\xff\"\n.file 3 \"/other/keep\" , 0x0U, 99";
    let expected = b".version 8.0\n/* .file 1 \"/root/ignored\" */\n.file 2 \"/override/\xff\", 1, 0\n.file 3 \"/other/keep\" , 1, 99";
    assert_eq!(
        normalize_source_info(source, &paths, true).as_deref(),
        Some(expected.as_slice()),
    );
}

#[test]
fn elf_parser_rejects_truncated_buffers() {
    let mut header = [0; 64];
    header[..6].copy_from_slice(b"\x7fELF\x02\x01");
    header[40..48].copy_from_slice(&64u64.to_le_bytes());
    header[58..60].copy_from_slice(&64u16.to_le_bytes());
    assert!(
        edit_elf_sections(
            header.as_mut_slice(),
            b".note.nv.tkinfo",
            blank_store_hashes
        )
        .is_err()
    );
}
