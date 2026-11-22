#pragma once

#include <algorithm>
#include <cstdint>
#include <elf.h>
#include <span>
#include <stdexcept>
#include <string_view>
#include <vector>

namespace cudaWrapper {

// Returns the n bytes at offset off of the output, or throws if they're outside it.
template <typename Output> std::vector<char> readBytes(Output &output, std::uint64_t off, std::uint64_t n) {
    if (off > output.size() || n > output.size() - off) throw std::runtime_error("the output is a malformed ELF file");
    return output.read(off, n);
}

template <typename T, typename Output> T readValue(Output &output, std::uint64_t off) {
    T value{};
    std::ranges::copy(readBytes(output, off, sizeof(T)), reinterpret_cast<char *>(&value));
    return value;
}

template <typename Output> bool isElf(Output &output) {
    if (output.size() < SELFMAG) return false;
    const auto magic = readBytes(output, 0, SELFMAG);
    return std::string_view(magic.data(), magic.size()) == ELFMAG;
}

// Transform named sections in place. The callback returns whether it changed
// their contents. Offsets and section sizes stay unchanged.
template <typename Output, typename Edit>
bool editElfSections(Output &output, std::string_view sectionName, Edit update) {
    const std::uint64_t size = output.size();
    const auto ehdr = readValue<Elf64_Ehdr>(output, 0);
    if (ehdr.e_ident[EI_CLASS] != ELFCLASS64 || ehdr.e_ident[EI_DATA] != ELFDATA2LSB ||
        ehdr.e_shentsize != sizeof(Elf64_Shdr))
        throw std::runtime_error("the output isn't a 64-bit little-endian ELF file");
    // With many sections, the number of sections and the index of the section names are in the first section header.
    const auto first = readValue<Elf64_Shdr>(output, ehdr.e_shoff);
    const std::uint64_t count = ehdr.e_shnum != 0 ? ehdr.e_shnum : first.sh_size;
    const std::uint64_t namesIndex = ehdr.e_shstrndx != SHN_XINDEX ? ehdr.e_shstrndx : first.sh_link;
    // Reading the first section header checked that e_shoff is within the output.
    if (ehdr.e_shoff == 0 || count > (size - ehdr.e_shoff) / sizeof(Elf64_Shdr) || namesIndex >= count)
        throw std::runtime_error("the output is a malformed ELF file");
    const auto section = [&](std::uint64_t i) {
        return readValue<Elf64_Shdr>(output, ehdr.e_shoff + i * sizeof(Elf64_Shdr));
    };
    const auto namesHeader = section(namesIndex);
    const auto namesBytes = readBytes(output, namesHeader.sh_offset, namesHeader.sh_size);
    const std::string_view names(namesBytes.data(), namesBytes.size());

    bool changed = false;
    for (std::uint64_t i = 0; i < count; i++) {
        const auto shdr = section(i);
        if (shdr.sh_name >= names.size()) throw std::runtime_error("the output is a malformed ELF file");
        const auto rest = names.substr(shdr.sh_name);
        const auto end = rest.find('\0');
        if (end == std::string_view::npos) throw std::runtime_error("the output is a malformed ELF file");
        if (shdr.sh_type == SHT_NOBITS || rest.substr(0, end) != sectionName) continue;
        auto contents = readBytes(output, shdr.sh_offset, shdr.sh_size);
        if (update(std::span<char>(contents))) {
            output.write(shdr.sh_offset, contents);
            changed = true;
        }
    }
    return changed;
}

} // namespace cudaWrapper
