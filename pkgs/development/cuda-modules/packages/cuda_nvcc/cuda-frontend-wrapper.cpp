#include "arguments.hpp"
#include "path-prefix-map.hpp"
#include "process.hpp"

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
        return command ? tool.exec(command->args, argv[0]) : tool.exec(argv);
    });
}
