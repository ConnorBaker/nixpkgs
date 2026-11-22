#pragma once

#include <algorithm>
#include <span>
#include <string_view>

namespace cudaWrapper {

// Overwrites with e's, as remove-references-to does, each hash of a path in the Nix store (32 characters of Nix's
// base-32 alphabet, which lacks e), which is what Nix looks for to find references, whatever the spelling of the path.
// Returns whether text changed.
inline bool blankStoreHashes(std::span<char> text) {
    bool changed = false;
    std::size_t run = 0;
    for (std::size_t i = 0; i < text.size(); i++) {
        run = std::string_view("0123456789abcdfghijklmnpqrsvwxyz").contains(text[i]) ? run + 1 : 0;
        if (run == 32) {
            std::ranges::fill(text.subspan(i - 31, 32), 'e');
            changed = true;
            run = 0;
        }
    }
    return changed;
}

} // namespace cudaWrapper
