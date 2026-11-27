use crate::path_prefix_map::PathPrefixMap;
use crate::ptx::normalize_source_info;

#[cfg(feature = "wrapper")]
#[test]
fn nvidia_option_quoting_preserves_raw_path_bytes() {
    use crate::arguments::{Quote, tokenize};

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
        normalize_source_info(source, &paths, true)
            .unwrap()
            .as_deref(),
        Some(expected.as_slice()),
    );
}
