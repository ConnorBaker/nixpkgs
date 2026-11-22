#pragma once

#include <charconv>
#include <cstdint>
#include <span>
#include <stdexcept>
#include <string_view>

namespace cudaWrapper {

// Clear member dates and ownership in regular ar archives. The member layout and symbol
// table offsets stay intact. Other outputs, such as standalone ELF objects,
// are passed through.
template <typename Output> void normalizeArchiveMetadata(Output &output) {
    constexpr std::string_view magic = "!<arch>\n";
    if (output.size() < magic.size()) return;
    const auto signature = output.read(0, magic.size());
    if (std::string_view(signature.data(), signature.size()) != magic) return;

    constexpr std::size_t headerSize = 60;
    constexpr std::size_t metadataOffset = 16;
    // The date, UID, and GID fields are adjacent.
    constexpr std::string_view metadata = "0           0     0     ";
    const auto malformed = [] { return std::runtime_error("the output is a malformed ar archive"); };
    for (std::uint64_t offset = magic.size(); offset < output.size();) {
        if (output.size() - offset < headerSize) throw malformed();
        const auto header = output.read(offset, headerSize);
        if (header[58] != '`' || header[59] != '\n') throw malformed();
        const std::string_view sizeField(header.data() + 48, 10);
        const auto sizeEnd = sizeField.find_last_not_of(' ');
        if (sizeEnd == std::string_view::npos) throw malformed();
        const auto *end = sizeField.data() + sizeEnd + 1;
        std::uint64_t size;
        const auto parsed = std::from_chars(sizeField.data(), end, size);
        if (parsed.ec != std::errc{} || parsed.ptr != end || size > output.size() - offset - headerSize ||
            size % 2 > output.size() - offset - headerSize - size)
            throw malformed();

        const std::string_view oldMetadata(header.data() + metadataOffset, metadata.size());
        // The GNU long-name table can have blank date and ownership fields.
        const bool blankLongNamesMetadata = header[0] == '/' && header[1] == '/' &&
                                            oldMetadata.find_first_not_of(' ') == std::string_view::npos;
        if (oldMetadata != metadata && !blankLongNamesMetadata)
            output.write(offset + metadataOffset, std::span(metadata));
        offset += headerSize + size + size % 2;
    }
}

} // namespace cudaWrapper
