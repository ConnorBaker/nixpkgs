#pragma once

#include <algorithm>
#include <cstdint>
#include <span>
#include <vector>

namespace cudaWrapper {

inline constexpr std::size_t nixStoreHashLength = 32;

inline bool isNixBase32(char byte) {
    return (byte >= '0' && byte <= '9') || (byte >= 'a' && byte <= 'd') || (byte >= 'f' && byte <= 'n') ||
           (byte >= 'p' && byte <= 's') || (byte >= 'v' && byte <= 'z');
}

// Replace complete groups of Nix base32 bytes with e's. Use only in metadata
// whose candidate references can all be removed.
inline bool blankStoreHashes(std::span<char> text) {
    bool changed = false;
    std::size_t run = 0;
    for (std::size_t i = 0; i < text.size(); i++) {
        run = isNixBase32(text[i]) ? run + 1 : 0;
        if (run == nixStoreHashLength) {
            std::ranges::fill(text.subspan(i + 1 - run, run), 'e');
            changed = true;
            run = 0;
        }
    }
    return changed;
}

// A candidate is a run of at least 32 Nix base32 bytes. The run length
// carries across positioned reads, which reuse one buffer.
template <typename Artifact> bool containsStoreHashCandidate(const Artifact &output) {
    constexpr std::uint64_t bufferSize = 64 * 1024;
    const auto size = output.size();
    if (size < nixStoreHashLength) return false;
    std::vector<char> buffer(std::min(size, bufferSize));
    std::size_t run = 0;
    for (std::uint64_t offset = 0; offset < size;) {
        auto bytes = std::span(buffer).first(std::min<std::uint64_t>(size - offset, buffer.size()));
        output.readInto(offset, bytes);
        for (const auto byte : bytes) {
            run = isNixBase32(byte) ? run + 1 : 0;
            if (run == nixStoreHashLength) return true;
        }
        offset += bytes.size();
    }
    return false;
}

} // namespace cudaWrapper
