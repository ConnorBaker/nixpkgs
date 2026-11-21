#include "process.hpp"

int main(int, char **argv) {
    return cudaWrapper::wrapperMain("tileiras", [&](const cudaWrapper::Tool &tool) {
        if (setenv("CUDA_ROOT", TILEIRAS_CUDA_ROOT, 0) != 0)
            throw std::runtime_error(std::string("cannot set CUDA_ROOT: ") + std::strerror(errno));
        return tool.exec(argv);
    });
}
