#pragma once

#include "files.hpp"
#include "path-prefix-map.hpp"

#include <algorithm>
#include <charconv>
#include <limits>

namespace cudaWrapper {

namespace ptxDetail {

using namespace std::literals;

inline bool identifier(char c) {
    return ('a' <= c && c <= 'z') || ('A' <= c && c <= 'Z') || ('0' <= c && c <= '9') || "._$%"sv.contains(c);
}

inline std::optional<std::uint64_t> integerLiteral(std::string_view value) {
    if (value.ends_with('U')) value.remove_suffix(1);
    int base = value.starts_with('0') ? 8 : 10;
    if (value.starts_with("0x") || value.starts_with("0X")) {
        base = 16;
        value.remove_prefix(2);
    } else if (value.starts_with("0b") || value.starts_with("0B")) {
        base = 2;
        value.remove_prefix(2);
    }
    if (value.empty()) return std::nullopt;
    std::uint64_t result;
    const auto end = value.data() + value.size();
    const auto parsed = std::from_chars(value.data(), end, result, base);
    if (parsed.ec != std::errc{} || parsed.ptr != end) return std::nullopt;
    return result;
}

// Read PTX tokens without mistaking comments, quoted strings, or .file as part
// of a longer identifier for a source-file directive.
inline std::string_view token(std::string_view &input) {
    while (!input.empty()) {
        if (" \t\r\n\f\v"sv.contains(input.front())) {
            input.remove_prefix(1);
        } else if (input.starts_with("//")) {
            const auto end = input.find('\n');
            input.remove_prefix(std::min(end, input.size()));
        } else if (input.starts_with("/*")) {
            const auto end = input.find("*/", 2);
            input.remove_prefix(end == std::string_view::npos ? input.size() : end + 2);
        } else {
            break;
        }
    }
    if (input.empty()) return {};
    std::size_t end = 1;
    if (input.front() == '"') {
        bool escaped = false;
        for (; end < input.size(); ++end) {
            if (!escaped && input[end] == '"') break;
            escaped = !escaped && input[end] == '\\';
        }
        if (end == input.size()) {
            input = {};
            return {};
        }
        ++end;
    } else if (identifier(input.front())) {
        while (end < input.size() && identifier(input[end])) ++end;
    }
    const auto result = input.substr(0, end);
    input.remove_prefix(end);
    return result;
}

inline std::string quote(std::string_view path) {
    std::string result = "\"";
    for (const char c : path) {
        if (c == '"' || c == '\\') result += '\\';
        result += c;
    }
    result += '"';
    return result;
}

} // namespace ptxDetail

inline std::optional<std::string> normalizePtxSourceInfo(std::string_view ptx, const PathPrefixMap &paths,
                                                        bool normalizeTimestamp = false) {
    using namespace ptxDetail;
    // Real PTX inputs include a version directive. Skip other operands and files.
    if (!ptx.contains(".file"sv)) return std::nullopt;
    auto input = ptx;
    if (token(input) != ".version") return std::nullopt;

    std::string result;
    std::size_t copied = 0;
    for (auto current = token(input); !current.empty(); current = token(input)) {
        if (current != ".file") continue;
        const auto index = token(input);
        const auto filename = token(input);
        if (!integerLiteral(index) || filename.size() < 2 || filename.front() != '"' || filename.back() != '"')
            continue;
        auto following = input;
        const bool hasMetadata = token(following) == ",";
        const auto timestamp = hasMetadata ? token(following) : std::string_view{};
        const bool addTimestamp = normalizeTimestamp && !hasMetadata;
        const bool replaceZero = normalizeTimestamp && integerLiteral(timestamp) == 0 && token(following) == ",";
        const auto path = filename.substr(1, filename.size() - 2);
        // Leave PTX's escaped filename spellings intact. Paths emitted by
        // nvcc and cicc on Linux normally contain no escapes.
        const auto mapped = path.contains('\\') ? std::nullopt : paths.remap(path);
        if (!addTimestamp && !replaceZero && !mapped) continue;
        const auto offset = static_cast<std::size_t>(filename.data() - ptx.data());
        result += ptx.substr(copied, offset - copied);
        result += mapped ? quote(*mapped) : std::string(filename);
        // ptxas interprets zero as a request to stat the source file. A
        // nonzero timestamp makes it use both fields as written.
        if (addTimestamp) result += ", 1, 0";
        copied = offset + filename.size();
        if (replaceZero) {
            const auto start = static_cast<std::size_t>(timestamp.data() - ptx.data());
            result += ptx.substr(copied, start - copied);
            result += '1';
            copied = start + timestamp.size();
        }
    }
    if (copied == 0) return std::nullopt;
    result += ptx.substr(copied);
    return result;
}

inline std::optional<FileDescriptor> rewrittenPtxInput(const std::string &path, const PathPrefixMap &paths,
                                                        bool normalizeTimestamp = false) {
    auto limit = std::numeric_limits<std::size_t>::max();
    std::string contents;
    try {
        contents = readOptionsFile(path, limit);
    } catch (const std::runtime_error &) {
        return std::nullopt;
    }
    if (const auto rewritten = normalizePtxSourceInfo(contents, paths, normalizeTimestamp))
        return anonymousInput("cuda-ptx-input", *rewritten);
    return std::nullopt;
}

} // namespace cudaWrapper
