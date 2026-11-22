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

enum class OptionKind { plain, operand, optionsFiles };

struct Argument {
    std::string_view name;
    std::string_view value;
    OptionKind kind;
    std::span<const std::string> words;

    std::string withValue(std::string replacement) const {
        if (kind != OptionKind::plain && words.size() == 1)
            return std::string(name) + '=' + replacement;
        return replacement;
    }
};

inline bool isOptionsFile(std::string_view name) { return name == "-optf" || name == "--options-file"; }
inline bool isOutputOption(std::string_view name) { return name == "-o" || name == "--output-file"; }
inline bool isInformational(std::string_view name) {
    return name == "-h" || name == "--help" || name == "-V" || name == "--version";
}

// Consume each operand in the same argument list as its option.
template <typename Classify, typename Visit>
void visitArguments(std::span<const std::string> args, const Classify &classify, const Visit &visit) {
    while (!args.empty()) {
        const std::string_view word = args.front();
        const auto name = word.substr(0, word.find('='));
        const auto kind = classify(name);
        auto value = word;
        std::size_t count = 1;
        if (kind != OptionKind::plain) {
            if (name.size() < word.size()) {
                value = word.substr(name.size() + 1);
            } else {
                if (args.size() == 1) throw OptionsError(std::string(name) + " is missing its value");
                value = args[1];
                count = 2;
            }
        }
        visit(Argument{name, value, kind, args.first(count)});
        args = args.subspan(count);
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

// Visit nested options in order while consuming operands within each file.
template <typename Classify, typename Visit>
void visitExpandedArguments(std::span<const std::string> args, const Classify &classify,
                            EscapedQuote escapedQuote, std::size_t byteLimit, const Visit &visit) {
    const auto walk = [&](this const auto &self, std::span<const std::string> input, unsigned depth) -> void {
        checkOptionsDepth(depth);
        visitArguments(input, classify, [&](const Argument &arg) {
            if (arg.kind == OptionKind::optionsFiles) {
                for (const auto part : std::views::split(arg.value, ',')) {
                    if (!part.empty()) self(readArguments(std::string(part.begin(), part.end()), escapedQuote, byteLimit),
                                            depth + 1);
                }
            } else {
                visit(arg);
            }
        });
    };
    walk(args, 0);
}

// Used by tools whose -o selects the artifact to edit.
template <typename Classify>
std::optional<std::string> lastOutput(std::span<const std::string> args, Classify classify) {
    std::optional<std::string> output;
    bool informational = false;
    visitExpandedArguments(args, classify, EscapedQuote::discard, std::numeric_limits<std::size_t>::max(),
        [&](const Argument &arg) {
            informational |= isInformational(arg.name);
            if (isOutputOption(arg.name)) output = arg.value;
        });
    return informational ? std::nullopt : output;
}

struct RewrittenArguments {
    Arguments args;
    std::vector<FileDescriptor> files;

    std::string addFile(FileDescriptor fd) {
        files.push_back(std::move(fd));
        return descriptorPath(files.back());
    }
};

inline std::string encodeOptions(std::span<const std::string> args) {
    std::string text;
    for (const auto &arg : args) {
        text += '"';
        for (const char c : arg) {
            if (c == '\\' || c == '"') text += '\\';
            text += c;
        }
        text += "\"\n";
    }
    return text;
}

// Keep each options file at its original position in the command, replacing
// only the files whose arguments changed. Flattening them into argv would
// impose the kernel's argument size limits on the caller.
template <typename Classify, typename Rewrite>
std::optional<RewrittenArguments> rewriteOptions(Arguments args, Classify classify, Rewrite rewrite) {
    RewrittenArguments result{std::move(args), {}};
    auto byteLimit = std::numeric_limits<std::size_t>::max();
    const auto rewriteList = [&](this const auto &self, Arguments &input, unsigned depth) -> bool {
        checkOptionsDepth(depth);
        bool changed = false;
        visitArguments(input, classify, [&](const Argument &arg) {
            std::optional<std::string> replacement;
            if (arg.kind == OptionKind::optionsFiles) {
                std::string paths;
                bool changedFile = false;
                for (const auto part : std::views::split(arg.value, ',')) {
                    if (part.begin() != arg.value.begin()) paths += ',';
                    if (part.empty()) continue;
                    std::string path(part.begin(), part.end());
                    auto nested = readArguments(path, EscapedQuote::discard, byteLimit);
                    if (self(nested, depth + 1)) {
                        path = result.addFile(anonymousInput("cuda-options", encodeOptions(nested)));
                        changedFile = true;
                    }
                    paths += path;
                }
                if (changedFile) replacement = std::move(paths);
            } else {
                replacement = rewrite(arg, result);
            }
            // These tools discard escaped double quotes in options files.
            if (!replacement || (depth != 0 && replacement->contains('"'))) return;
            const auto index = arg.words.data() - input.data() + arg.words.size() - 1;
            input[index] = arg.withValue(std::move(*replacement));
            changed = true;
        });
        return changed;
    };
    try {
        if (rewriteList(result.args, 0)) return result;
    } catch (const OptionsError &) {
        // Preserve the vendor's diagnostics for options we cannot inspect.
    }
    return std::nullopt;
}

} // namespace cudaWrapper
