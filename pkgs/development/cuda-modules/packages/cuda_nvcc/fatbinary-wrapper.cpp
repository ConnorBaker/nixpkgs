#include "arguments.hpp"
#include "process.hpp"
#include "ptx.hpp"

#include <algorithm>
#include <array>

namespace {

using namespace std::literals;
using cudaWrapper::OptionKind;

OptionKind classify(std::string_view name) {
    if (cudaWrapper::isOptionsFile(name)) return OptionKind::optionsFiles;
    constexpr std::array operands{
        "-ident"sv, "--ident"sv, "-image3"sv, "--image3"sv, "-image2"sv, "--image2"sv, "-create"sv, "--create"sv,
        "-fatbin"sv, "--embedded-fatbin"sv, "-cmdline"sv, "--cmdline"sv, "-cicc-cmdline"sv, "--cicc-cmdline"sv,
        "-tileir-cmdline"sv, "--tileir-cmdline"sv, "-compress"sv, "--compress"sv,
        "-compress-mode"sv, "--compress-mode"sv,
    };
    return std::ranges::contains(operands, name) ? OptionKind::operand : OptionKind::plain;
}

std::optional<std::string> remapImage(std::string_view image, const cudaWrapper::PathPrefixMap &paths,
                                      cudaWrapper::RewrittenArguments &inputs) {
    std::optional<std::string_view> filename;
    bool ptx = false;
    for (const auto field : std::views::split(image, ',')) {
        const std::string_view value(field.begin(), field.end());
        if (value == "kind=ptx") ptx = true;
        if (value.starts_with("file=")) {
            // Each image specification contains a single file field.
            if (filename) return std::nullopt;
            filename = value.substr(5);
        }
    }
    if (!ptx || !filename) return std::nullopt;

    auto rewritten = cudaWrapper::rewrittenPtxInput(std::string(*filename), paths);
    if (!rewritten) return std::nullopt;
    const auto start = static_cast<std::size_t>(filename->data() - image.data());
    return std::string(image.substr(0, start)) + inputs.addFile(std::move(*rewritten)) +
           std::string(image.substr(start + filename->size()));
}

int run(const cudaWrapper::Tool &tool, int argc, char **argv) {
    const cudaWrapper::PathPrefixMap paths(cudaWrapper::environment("BUILD_PATH_PREFIX_MAP"));
    if (paths.empty()) return tool.exec(argv);
    const auto command = cudaWrapper::rewriteOptions({argv + 1, argv + argc}, classify,
        [&](const cudaWrapper::Argument &arg, cudaWrapper::RewrittenArguments &inputs) -> std::optional<std::string> {
            if (arg.name == "--ident" || arg.name == "-ident") return paths.remap(arg.value);
            if (arg.name == "--image3" || arg.name == "-image3" || arg.name == "--image2" || arg.name == "-image2")
                return remapImage(arg.value, paths, inputs);
            return std::nullopt;
        });
    if (command) return tool.exec(command->args, argv[0]);
    return tool.exec(argv);
}

} // namespace

int main(int argc, char **argv) {
    return cudaWrapper::wrapperMain("fatbinary", [&](const cudaWrapper::Tool &tool) { return run(tool, argc, argv); });
}
