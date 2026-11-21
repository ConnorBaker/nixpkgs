// Pass reproducibility options to NVIDIA's nvcc. See README.md.
#include "arguments.hpp"
#include "process.hpp"
#include "ptx.hpp"
#include "scratch.hpp"

#include <algorithm>
#include <array>

namespace {

namespace fs = std::filesystem;
using namespace std::literals;
using cudaWrapper::Arguments;
using cudaWrapper::environment;

std::string_view optionName(std::string_view spelling) {
    if (!spelling.starts_with('-')) return {};
    return spelling.substr(spelling.starts_with("--") ? 2 : 1);
}

// These options can take a path or free-form value in the next argument.
// Count only positional source files, never a filename used as an operand.
constexpr std::array operands{
    "include"sv, "pre-include"sv, "I"sv, "include-path"sv,
    "isystem"sv, "system-include"sv, "L"sv, "library-path"sv, "l"sv, "library"sv, "D"sv, "define-macro"sv,
    "U"sv, "undefine-macro"sv, "ccbin"sv, "compiler-bindir"sv, "arbin"sv, "archiver-binary"sv, "ldir"sv,
    "libdevice-directory"sv, "apply-controls"sv, "MF"sv, "dependency-output"sv, "MT"sv, "dependency-target-name"sv,
    "Xcompiler"sv, "compiler-options"sv, "Xlinker"sv, "linker-options"sv, "Xarchive"sv, "archive-options"sv,
    "Xptxas"sv, "ptxas-options"sv, "Xnvlink"sv, "nvlink-options"sv, "Xnvprune"sv, "nvprune-options"sv, "Xtileiras"sv,
    "tileiras-options"sv, "time"sv, "fdevice-time-trace"sv, "run-args"sv,
    "create-pch"sv, "use-pch"sv, "pch-dir"sv, "qpp-config"sv,
};

bool takesOperand(std::string_view name) {
    return name == "keep-dir" || name == "frandom-seed" || name == "x" ||
           name == "o" || name == "output-file" || name == "odir" || name == "output-directory" ||
           std::ranges::contains(operands, name);
}

struct Compilation {
    Arguments sources;
    std::optional<std::string> output;
    fs::path outputDirectory;
    bool keep = true;
    bool seed = NVCC_HAS_RANDOM_SEED;
    bool ptx = false;

    Arguments ptxPaths() const {
        if (output) return {*output};
        Arguments paths;
        for (const auto &source : sources) {
            auto name = fs::path(source).filename();
            name.replace_extension(".ptx");
            auto path = (outputDirectory / name).native();
            if (!std::ranges::contains(paths, path)) paths.push_back(std::move(path));
        }
        return paths;
    }
};

std::optional<Compilation> inspect(const Arguments &args) {
    Compilation build;
    Arguments inputs;
    bool explicitLanguage = false;
    for (std::size_t i = 0; i < args.size(); ++i) {
        const std::string_view arg = args[i];
        const cudaWrapper::Option option(arg);
        const auto name = optionName(option.name);
        if (name == "dryrun" || name == "version" || name == "V" || name == "h" || name == "help" ||
            name == "E" || name == "preprocess" || name == "M" || name == "MM" || name == "generate-dependencies" ||
            name == "generate-nonsystem-dependencies" || name == "clean" || name == "clean-targets")
            return std::nullopt;
        if (name == "keep" || name == "keep-dir" || name == "save-temps" ||
            name == "objdir-as-tempdir" || name == "objtemp")
            build.keep = false;
        if (name == "frandom-seed") build.seed = false;
        if (name == "ptx") build.ptx = true;
        if (name == "o" || name == "output-file") {
            build.output = option.value(args, i);
        } else if (name == "odir" || name == "output-directory") {
            build.outputDirectory = option.value(args, i);
        } else if (name == "x") {
            const auto lang = option.value(args, i);
            explicitLanguage = lang == "cu" || lang == "c++" || lang == "c";
        } else if (!option.inlineValue && takesOperand(name)) {
            ++i;
        } else if (!arg.empty() && !arg.starts_with('-')) {
            inputs.emplace_back(arg);
        }
    }
    constexpr std::array extensions{".cu"sv, ".c"sv, ".cc"sv, ".cxx"sv, ".cpp"sv, ".c++"sv, ".C"sv, ".CPP"sv};
    Arguments stems;
    for (const auto &input : inputs) {
        const fs::path path(input);
        if (!explicitLanguage && !std::ranges::contains(extensions, path.extension().native())) continue;
        const auto stem = path.stem().native();
        if (std::ranges::contains(stems, stem)) build.keep = false;
        stems.push_back(stem);
        build.sources.push_back(input);
    }
    if (build.sources.empty()) return std::nullopt;
    // nvcc takes one seed per invocation. A shared seed would violate NVIDIA's
    // requirement for separate seeds when compiling separate translation units.
    if (build.sources.size() != 1) build.seed = false;
    return build;
}

std::optional<Arguments> effectiveArguments(const Arguments &args) {
    using cudaWrapper::EscapedQuote;
    using cudaWrapper::OptionKind;
    try {
        auto supplied = cudaWrapper::tokenize(environment("NVCC_PREPEND_FLAGS"), EscapedQuote::preserve);
        supplied.insert(supplied.end(), args.begin(), args.end());
        const auto appended = cudaWrapper::tokenize(environment("NVCC_APPEND_FLAGS"), EscapedQuote::preserve);
        supplied.insert(supplied.end(), appended.begin(), appended.end());

        return cudaWrapper::expandOptions(supplied, [](std::string_view spelling) {
            const auto name = optionName(spelling);
            if (name == "optf" || name == "options-file") return OptionKind::optionsFiles;
            return takesOperand(name) ? OptionKind::operand : OptionKind::plain;
        }, EscapedQuote::preserve, 4 * 1024 * 1024);
    } catch (const cudaWrapper::OptionsError &) {
        // Let nvcc handle invocations whose options could not be inspected.
        return std::nullopt;
    }
}

int compile(const cudaWrapper::Tool &tool, const Arguments &args) {
    const auto effective = effectiveArguments(args);
    if (!effective) return tool.exec(args);
    const auto build = inspect(*effective);
    if (!build) return tool.exec(args);

    std::error_code error;
    const auto cwd = fs::current_path(error);
    if (error) return tool.exec(args);

    Arguments command;
    if (build->seed)
        command.push_back("--frandom-seed=nvcc-" + cudaWrapper::stableId(cwd.native(), build->sources));

    std::optional<cudaWrapper::ScratchDirectory> scratch;
    if (build->keep) {
        const auto tmp = environment("TMPDIR");
        const auto id = cudaWrapper::stableId(cwd.native(), *effective);
        const auto path = fs::path(tmp.empty() ? "/tmp"sv : tmp) / ("nvcc-keep-" + id);
        scratch.emplace(path, "nvcc");
        if (*scratch) {
            command.emplace_back("--keep");
            command.push_back("--keep-dir=" + path.native());
        }
    }

    command.insert(command.end(), args.begin(), args.end());
    const cudaWrapper::PathPrefixMap paths(build->ptx ? environment("BUILD_PATH_PREFIX_MAP") : "");
    std::vector<cudaWrapper::GeneratedFile> ptxOutputs;
    if (!paths.empty()) {
        for (auto &path : build->ptxPaths()) {
            if (path != "-" && path != "/dev/stdout" && !cudaWrapper::isSpecialFile(path))
                ptxOutputs.emplace_back(std::move(path));
        }
    }

    if ((!scratch || !*scratch) && ptxOutputs.empty()) return tool.exec(command);
    const int status = tool.run(command, scratch ? scratch->descriptor() : -1);
    scratch.reset();
    const int result = cudaWrapper::exitStatus(status);
    if (result == 0) {
        for (auto &output : ptxOutputs)
            output.rewriteText("nvcc", [&](std::string_view ptx) { return cudaWrapper::normalizePtxSourceInfo(ptx, paths); });
    }
    return result;
}

} // namespace

int main(int argc, char **argv) {
    return cudaWrapper::wrapperMain("nvcc", [&](const cudaWrapper::Tool &tool) {
        std::string path = NVCC_BACKEND_BIN;
        if (const auto old = environment("PATH"); !old.empty()) {
            path += ':';
            path += old;
        }
        if (setenv("PATH", path.c_str(), 1) != 0)
            throw std::runtime_error(std::string("cannot set PATH: ") + std::strerror(errno));
        return compile(tool, Arguments(argv + 1, argv + argc));
    });
}
