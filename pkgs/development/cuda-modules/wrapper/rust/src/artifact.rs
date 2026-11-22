use crate::files::Artifact;
use std::io;

const SECTION_SIZE: u64 = 64;

pub fn blank_store_hashes(bytes: &mut [u8]) -> bool {
    const ALPHABET: &[u8] = b"0123456789abcdfghijklmnpqrsvwxyz";
    let mut changed = false;
    let mut run = 0;
    for index in 0..bytes.len() {
        run = if ALPHABET.contains(&bytes[index]) {
            run + 1
        } else {
            0
        };
        if run == 32 {
            bytes[index + 1 - run..=index].fill(b'e');
            changed = true;
            run = 0;
        }
    }
    changed
}

pub fn is_elf(output: &Artifact<'_>) -> io::Result<bool> {
    Ok(output.size() >= 4 && output.read(0, 4)? == b"\x7fELF")
}

// Update named sections in place and preserve their layout and size. Both
// supported CUDA hosts use ELF64 little-endian objects.
pub fn edit_elf_sections(
    output: &mut Artifact<'_>,
    name: &[u8],
    mut update: impl FnMut(&mut [u8]) -> bool,
) -> io::Result<bool> {
    const HEADER_SIZE: u64 = 64;
    const SHN_XINDEX: u64 = 0xffff;
    const SHT_NOBITS: u64 = 8;
    let malformed = || io::Error::other("the output is a malformed ELF file");
    let header = output.read(0, HEADER_SIZE).map_err(|_| malformed())?;
    if header[..6] != *b"\x7fELF\x02\x01" || little_endian(&header[58..60]) != SECTION_SIZE {
        return Err(io::Error::other(
            "the output isn't a 64-bit little-endian ELF file",
        ));
    }

    let section_offset = little_endian(&header[40..48]);
    if section_offset == 0 || section_offset > output.size() {
        return Err(malformed());
    }
    let section = |index| section_offset + index * SECTION_SIZE;
    let first = output.read(section(0), SECTION_SIZE)?;
    let mut count = little_endian(&header[60..62]);
    let mut names_index = little_endian(&header[62..64]);
    if count == 0 {
        count = little_endian(&first[32..40]);
    }
    if names_index == SHN_XINDEX {
        names_index = little_endian(&first[40..44]);
    }
    if count > (output.size() - section_offset) / SECTION_SIZE || names_index >= count {
        return Err(malformed());
    }
    let strtab = output.read(section(names_index), SECTION_SIZE)?;
    let names = output.read(
        little_endian(&strtab[24..32]),
        little_endian(&strtab[32..40]),
    )?;
    let mut changed = false;
    for index in 0..count {
        let header = output.read(section(index), SECTION_SIZE)?;
        let name_offset = little_endian(&header[..4]) as usize;
        let rest = names.get(name_offset..).ok_or_else(malformed)?;
        let end = rest.iter().position(|&b| b == 0).ok_or_else(malformed)?;
        if &rest[..end] == name && little_endian(&header[4..8]) != SHT_NOBITS {
            let offset = little_endian(&header[24..32]);
            let mut contents = output.read(offset, little_endian(&header[32..40]))?;
            if update(&mut contents) {
                output.write(offset, &contents)?;
                changed = true;
            }
        }
    }
    Ok(changed)
}

fn little_endian(bytes: &[u8]) -> u64 {
    let mut word = [0; 8];
    word[..bytes.len()].copy_from_slice(bytes);
    u64::from_le_bytes(word)
}

pub fn normalize_archive_dates(output: &mut Artifact<'_>) -> io::Result<()> {
    const MAGIC: &[u8] = b"!<arch>\n";
    const HEADER_SIZE: u64 = 60;
    const DATE: &[u8; 12] = b"0           ";
    let mut offset = MAGIC.len() as u64;
    if output.size() < offset || output.read(0, offset)? != MAGIC {
        return Ok(());
    }

    let malformed = || io::Error::other("the output is a malformed ar archive");
    while offset < output.size() {
        let header = output.read(offset, HEADER_SIZE).map_err(|_| malformed())?;
        if &header[58..60] != b"`\n" {
            return Err(malformed());
        }
        let field = header[48..58].trim_ascii_end();
        let size = std::str::from_utf8(field)
            .ok()
            .filter(|_| field.iter().all(u8::is_ascii_digit))
            .and_then(|size| size.parse::<u64>().ok())
            .ok_or_else(malformed)?;
        let available = output.size() - offset - HEADER_SIZE;
        if size > available || size % 2 > available - size {
            return Err(malformed());
        }
        let old_date = &header[16..28];
        let blank_names_date = header.starts_with(b"//") && old_date.iter().all(|&b| b == b' ');
        if old_date != DATE && !blank_names_date {
            output.write(offset + 16, DATE)?;
        }
        offset += HEADER_SIZE + size + size % 2;
    }
    Ok(())
}
