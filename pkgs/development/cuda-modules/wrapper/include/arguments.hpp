#pragma once

#include "files.hpp"

#include <limits>
#include <ranges>
#include <span>
#include <string>
#include <string_view>
#include <vector>

namespace cudaWrapper {

using Arguments = std::vector<std::string>;

struct OptionsError : std::runtime_error {
    using std::runtime_error::runtime_error;
};

enum class EscapedQuote { preserve, discard };

// NVIDIA options files and flag variables use whitespace, double quotes and
// backslash escapes. nvlink discards an escaped double quote.
inline Arguments tokenize(std::string_view text, EscapedQuote escapedQuote) {
    Arguments args;
    std::optional<std::string> word;
    bool quoted = false;
    bool escaped = false;
    for (const char c : text) {
        if (!escaped && c == '\\') {
            escaped = true;
        } else if (!escaped && c == '"') {
            quoted = !quoted;
            if (!word) word.emplace();
        } else if (!escaped && !quoted && std::string_view(" \t\n\r\f\v").contains(c)) {
            if (word) args.push_back(std::move(*word));
            word.reset();
        } else {
            if (!word) word.emplace();
            if (c != '"' || escapedQuote == EscapedQuote::preserve) *word += c;
            escaped = false;
        }
    }
    if (escaped || quoted) throw OptionsError("an options file ends in a backslash or a quotation");
    if (word) args.push_back(std::move(*word));
    return args;
}

struct Option {
    std::string_view name;
    std::optional<std::string_view> inlineValue;

    explicit Option(std::string_view arg) : name(arg.substr(0, arg.find('='))) {
        if (name.size() != arg.size()) inlineValue = arg.substr(name.size() + 1);
    }

    std::string_view value(std::span<const std::string> args, std::size_t &index) const {
        if (inlineValue) return *inlineValue;
        if (index + 1 == args.size()) throw OptionsError(std::string(name) + " is missing its value");
        return args[++index];
    }
};

enum class OptionKind { plain, operand, optionsFiles };

inline bool isOptionsFile(std::string_view name) { return name == "-optf" || name == "--options-file"; }
inline bool isOutputOption(std::string_view name) { return name == "-o" || name == "--output-file"; }
inline bool isInformational(std::string_view name) {
    return name == "-h" || name == "--help" || name == "-V" || name == "--version";
}

// Consume each operand in the same argument list as its option.
template <typename Classify, typename Visit>
void visitArguments(std::span<const std::string> args, Classify classify, Visit visit) {
    for (std::size_t i = 0; i < args.size(); ++i) {
        const auto start = i;
        const Option option(args[i]);
        const auto kind = classify(option.name);
        const auto value = kind == OptionKind::plain ? std::string_view(args[i]) : option.value(args, i);
        visit(option, kind, value, start, i);
    }
}

inline Arguments readArguments(const std::string &path, EscapedQuote escapedQuote, std::size_t &byteLimit) {
    try {
        return tokenize(readOptionsFile(path, byteLimit), escapedQuote);
    } catch (const std::runtime_error &error) {
        throw OptionsError(error.what());
    }
}

inline void checkOptionsDepth(unsigned depth) {
    if (depth == 16) throw OptionsError("options files are nested too deeply");
}

// Expand comma-separated options files for inspection.
template <typename Classify>
Arguments expandOptions(std::span<const std::string> args, Classify classify, EscapedQuote escapedQuote,
                        std::size_t byteLimit = std::numeric_limits<std::size_t>::max()) {
    Arguments expanded;
    const auto append = [&](auto &recurse, std::span<const std::string> input, unsigned depth) -> void {
        checkOptionsDepth(depth);
        visitArguments(input, classify, [&](const Option &, OptionKind kind, std::string_view value,
                                           std::size_t start, std::size_t end) {
            if (kind == OptionKind::optionsFiles) {
                for (const auto part : std::views::split(value, ','))
                    if (!part.empty())
                        recurse(recurse, readArguments(std::string(part.begin(), part.end()), escapedQuote, byteLimit),
                                depth + 1);
            } else {
                const auto words = input.subspan(start, end - start + 1);
                expanded.insert(expanded.end(), words.begin(), words.end());
            }
        });
    };
    append(append, args, 0);
    return expanded;
}

// Used by tools whose -o selects the artifact to edit.
template <typename Classify>
std::optional<std::string> lastOutput(std::span<const std::string> args, Classify classify) {
    const auto expanded = expandOptions(args, classify, EscapedQuote::discard);
    std::optional<std::string> output;
    bool informational = false;
    visitArguments(expanded, classify, [&](const Option &option, OptionKind, std::string_view value, auto, auto) {
        if (isInformational(option.name)) informational = true;
        if (isOutputOption(option.name)) output = value;
    });
    return informational ? std::nullopt : output;
}

} // namespace cudaWrapper
