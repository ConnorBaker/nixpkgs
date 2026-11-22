#include "arguments.hpp"
#include "path-prefix-map.hpp"
#include "process.hpp"

#include <cerrno>
#include <cstdlib>
#include <filesystem>
#include <system_error>

namespace {

// cicc uses PWD for debug and LTO metadata when it names the current directory.
void setMappedWorkingDirectory(const cudaWrapper::PathPrefixMap &paths) {
    namespace fs = std::filesystem;
    std::error_code error;
    const auto cwd = fs::current_path(error);
    if (error) return;
    const auto mapped = paths.remap(cwd.native());
    if (mapped && fs::path(*mapped).is_absolute() && fs::equivalent(".", *mapped, error) &&
        setenv("PWD", mapped->c_str(), 1) != 0)
        throw std::system_error(errno, std::generic_category(), "setting PWD for cicc");
}

} // namespace

int main(int argc, char **argv) {
    return cudaWrapper::wrapperMain([&](const cudaWrapper::Tool &tool) {
        const cudaWrapper::PathPrefixMap paths(cudaWrapper::environment("BUILD_PATH_PREFIX_MAP"));
        if (paths.empty()) return tool.exec(argv);

        using cudaWrapper::OptionKind;
        const auto command = cudaWrapper::rewriteOptions({argv + 1, argv + argc},
            [](std::string_view name) {
                return name == "--orig_src_path_name" ? OptionKind::operand : OptionKind::plain;
            },
            [&](const cudaWrapper::Argument &arg, auto &) -> std::optional<std::string> {
                if (arg.kind == OptionKind::operand) return paths.remap(arg.value);
                return std::nullopt;
            });
        if (tool.name() == "cicc") setMappedWorkingDirectory(paths);
        return command ? tool.exec(command->args, argv[0]) : tool.exec(argv);
    });
}
