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
        "-o"sv, "--output-file"sv, "-arch"sv, "--gpu-name"sv, "-O"sv, "--opt-level"sv, "-m"sv, "--machine"sv,
        "-e"sv, "--entry"sv, "-ias"sv, "--input-as-string"sv, "-Ofc"sv, "--Ofast-compile"sv,
        "-dlcm"sv, "--def-load-cache"sv, "-dscm"sv, "--def-store-cache"sv, "-flcm"sv, "--force-load-cache"sv,
        "-fmad"sv, "--fmad"sv, "-func-maxrregcount"sv, "--device-function-maxrregcount"sv, "-maxntid"sv, "--maxntid"sv,
        "-maxrregcount"sv, "--maxrregcount"sv, "-minnctapersm"sv, "--minnctapersm"sv, "-pic"sv, "--position-independent-code"sv,
        "-regUsageLevel"sv, "--register-usage-level"sv, "-split-compile"sv, "--split-compile"sv,
        "-allow-expensive-optimizations"sv, "--allow-expensive-optimizations"sv,
        "-device-stack-protector"sv, "--device-stack-protector"sv, "-apply-controls"sv, "--apply-controls"sv,
        "-enable-func-clone-sc"sv, "--enable-func-clone-sc"sv, "-sanitize"sv, "--sanitize"sv, "--nv-host"sv,
    };
    return std::ranges::contains(operands, name) ? OptionKind::operand : OptionKind::plain;
}

int run(const cudaWrapper::Tool &tool, int argc, char **argv) {
    const cudaWrapper::PathPrefixMap paths(cudaWrapper::environment("BUILD_PATH_PREFIX_MAP"));
    if (!PTXAS_INHERITS_MTIME && paths.empty()) return tool.exec(argv);
    bool informational = false;
    try {
        const auto command = cudaWrapper::rewriteOptions({argv + 1, argv + argc}, classify,
            [&](std::string_view name, OptionKind kind, std::string_view value,
                cudaWrapper::RewrittenArguments &inputs) -> std::optional<std::string> {
                if (cudaWrapper::isInformational(name)) informational = true;
                if (informational) return std::nullopt;
                if (name == "-ias" || name == "--input-as-string")
                    return cudaWrapper::normalizePtxSourceInfo(value, paths, PTXAS_INHERITS_MTIME);
                if (kind == OptionKind::plain && !value.starts_with('-'))
                    if (auto fd = cudaWrapper::rewrittenPtxInput(std::string(value), paths, PTXAS_INHERITS_MTIME))
                        return inputs.addFile(std::move(*fd));
                return std::nullopt;
            });
        if (command && !informational) return tool.exec(command->args, argv[0]);
    } catch (const cudaWrapper::OptionsError &) {
        // Preserve the vendor's diagnostics for invocations we cannot inspect.
    }
    return tool.exec(argv);
}

} // namespace

int main(int argc, char **argv) {
    return cudaWrapper::wrapperMain("ptxas", [&](const cudaWrapper::Tool &tool) { return run(tool, argc, argv); });
}
