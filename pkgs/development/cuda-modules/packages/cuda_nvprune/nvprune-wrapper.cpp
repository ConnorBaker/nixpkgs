#include "archive.hpp"
#include "arguments.hpp"
#include "process.hpp"

namespace {

cudaWrapper::OptionKind classify(std::string_view name) {
    using cudaWrapper::OptionKind;
    if (cudaWrapper::isOptionsFile(name)) return OptionKind::optionsFiles;
    if (cudaWrapper::isOutputOption(name) || name == "-arch" || name == "--arch" ||
        name == "-gencode" || name == "--generate-code") return OptionKind::operand;
    return OptionKind::plain;
}

} // namespace

int main(int argc, char **argv) {
    return cudaWrapper::wrapperMain("nvprune", [&](const cudaWrapper::Tool &tool) {
        std::optional<std::string> path;
        try {
            path = cudaWrapper::lastOutput(cudaWrapper::Arguments(argv + 1, argv + argc), classify);
        } catch (const cudaWrapper::OptionsError &) {
            return tool.exec(argv);
        }
        if (!path) return tool.exec(argv);
        if (cudaWrapper::isSpecialFile(*path)) return tool.exec(argv);

        return tool.editOutput(argv, std::move(*path), [](auto &file) { cudaWrapper::normalizeArchiveDates(file); });
    });
}
