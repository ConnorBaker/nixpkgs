// Scrub build references from metadata recorded by NVIDIA's nvlink. See README.md.
#include "arguments.hpp"
#include "elf.hpp"
#include "nix-store.hpp"

#include <array>

#ifndef NVLINK_WRAPPER_NO_MAIN
#include "process.hpp"
#endif

namespace {

using namespace std::literals;
using cudaWrapper::OptionKind;

std::optional<std::string> findOutput(std::span<const std::string> args) {
    return cudaWrapper::lastOutput(args, [](std::string_view name) {
        // Only free-form operands can look like -o or an options-file flag.
        constexpr std::array freeFormOperands{
            "-L"sv, "--library-path"sv, "-l"sv, "--library"sv, "-Xnvvm"sv, "--Xnvvm"sv, "-Xptxas"sv, "--Xptxas"sv,
            "-kernels-used"sv, "--kernels-used"sv, "-variables-used"sv, "--variables-used"sv,
            "--register-link-binaries"sv, "-nvvmpath"sv, "--nvvmpath"sv, "-uidx"sv, "--uidx-file"sv,
            "-time"sv, "--time"sv, "-host-ccbin"sv, "--host-ccbin"sv,
        };
        if (cudaWrapper::isOptionsFile(name)) return OptionKind::optionsFiles;
        return cudaWrapper::isOutputOption(name) || std::ranges::contains(freeFormOperands, name)
            ? OptionKind::operand : OptionKind::plain;
    });
}

template <typename Output> bool scrub(Output &output) {
    if (cudaWrapper::isElf(output))
        return cudaWrapper::editElfSections(output, ".note.nv.tkinfo", cudaWrapper::blankStoreHashes);

    // Non-ELF outputs, such as host linker scripts, can contain live paths.
    if (cudaWrapper::containsStoreHashCandidate(output))
        throw std::runtime_error("the non-ELF output contains a possible Nix store reference");
    return false;
}

#ifdef NVLINK_WRAPPER_NO_MAIN

bool scrub(std::span<char> bytes) {
    cudaWrapper::MemoryBuffer buffer(bytes);
    return scrub(buffer);
}

#endif

} // namespace

#ifndef NVLINK_WRAPPER_NO_MAIN

int main(int argc, char **argv) {
    return cudaWrapper::wrapperMain("nvlink", [&](const cudaWrapper::Tool &tool) {
        auto path = findOutput(cudaWrapper::Arguments(argv + 1, argv + argc));
        if (!path) return cudaWrapper::exitStatus(tool.run(argv));
        return tool.editOutput(argv, std::move(*path), [](auto &file) { scrub(file); });
    });
}

#endif
