#pragma once

#include "files.hpp"

#include <cerrno>
#include <csignal>
#include <cstring>
#include <cstdlib>
#include <fcntl.h>
#include <filesystem>
#include <iostream>
#include <span>
#include <string>
#include <string_view>
#include <sys/prctl.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#include <vector>

namespace cudaWrapper {

inline std::string_view environment(const char *name) {
    if (const char *value = std::getenv(name)) return value;
    return {};
}

// Resolve the actual installed path, including when invoked through a symlink.
inline std::filesystem::path executable() {
    std::error_code error;
    const auto self = std::filesystem::read_symlink("/proc/self/exe", error);
    if (error) throw std::runtime_error("cannot find the wrapper: " + error.message());
    return self;
}

// Whether the wrapper is in the foreground process group of its controlling terminal.
inline bool inForeground() {
    const FileDescriptor tty(open("/dev/tty", O_RDONLY | O_NOCTTY | O_CLOEXEC));
    return tty && tcgetpgrp(tty.get()) == getpgrp();
}

inline int exec(const std::string &program, char *const argv[], std::string_view wrapper) {
    execv(program.c_str(), argv);
    std::cerr << wrapper << " wrapper: error: execv " << program << ": " << std::strerror(errno) << '\n';
    return 127;
}

// Runs the wrapped program with argv and returns its wait status.
inline int run(const std::string &program, char *const argv[], std::string_view wrapper, int inheritedFd = -1) {
    // An ignored SIGCHLD, which is inherited, would let the kernel reap the program without telling the wrapper.
    static_cast<void>(std::signal(SIGCHLD, SIG_DFL));
    // Receive the signals to forward, and SIGCHLD, synchronously rather than in a handler.
    sigset_t signals;
    sigset_t original;
    sigemptyset(&signals);
    for (const int sig : {SIGHUP, SIGINT, SIGQUIT, SIGTERM, SIGUSR1, SIGUSR2, SIGCHLD}) sigaddset(&signals, sig);
    sigprocmask(SIG_BLOCK, &signals, &original);

    // In the foreground of a terminal, the program stays in the wrapper's process group, so that it receives the signals
    // from the terminal itself and the wrapper doesn't forward them. Otherwise the program gets a process group of its own,
    // so that a signal sent to the wrapper's process group (e.g. by timeout) can be forwarded to the whole tool tree.
    const bool foreground = inForeground();
    const pid_t parent = getpid();
    const pid_t child = fork();
    if (child < 0) throw std::runtime_error(std::string("fork: ") + std::strerror(errno));
    if (child == 0) {
        // Don't outlive the wrapper.
        if (prctl(PR_SET_PDEATHSIG, SIGKILL) != 0 || getppid() != parent) _exit(127);
        if (!foreground && setpgid(0, 0) != 0) _exit(127);
        // Preserve the caller's standard descriptors even if the lease used a closed one.
        if (inheritedFd >= 0 && fcntl(inheritedFd, F_DUPFD, STDERR_FILENO + 1) < 0) {
            std::cerr << wrapper << " wrapper: error: cannot inherit descriptor: " << std::strerror(errno) << '\n';
            _exit(127);
        }
        sigprocmask(SIG_SETMASK, &original, nullptr);
        _exit(exec(program, argv, wrapper));
    }

    // Either process can run first. Assign the group before forwarding a pending signal.
    if (!foreground) static_cast<void>(setpgid(child, child));
    for (;;) {
        siginfo_t info;
        if (sigwaitinfo(&signals, &info) < 0) continue; // EINTR
        if (info.si_signo != SIGCHLD) {
            if (!foreground) {
                kill(-child, info.si_signo);
            } else if (info.si_code != SI_KERNEL) {
                kill(child, info.si_signo);
            }
            continue;
        }
        int status = 0;
        if (waitpid(child, &status, WNOHANG) == child) {
            sigprocmask(SIG_SETMASK, &original, nullptr);
            return status;
        }
    }
}

// Reproduce signal termination after the caller has cleaned up.
inline int exitStatus(int status) {
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    const int signal = WTERMSIG(status);
    static_cast<void>(std::signal(signal, SIG_DFL));
    static_cast<void>(std::raise(signal));
    return 128 + signal;
}

// A public tool and its vendor executable installed beside it.
class Tool {
  public:
    explicit Tool(std::string name) : name_(std::move(name)) {
        const auto bin = executable().parent_path();
        public_ = bin / name_;
        wrapped_ = bin / ("." + name_ + "-wrapped");
    }

    // Forward argv[0] verbatim when the vendor tool records the invocation name.
    int run(char *const argv[]) const { return cudaWrapper::run(wrapped_, argv, name_); }
    int exec(char *const argv[]) const { return cudaWrapper::exec(wrapped_, argv, name_); }
    int exec(std::span<const std::string> args, const char *argv0) const { return exec(command(args, argv0).data()); }

    // Use the installed public path for tools which locate their profile via argv[0].
    int run(std::span<const std::string> args, int inheritedFd = -1) const {
        return cudaWrapper::run(wrapped_, command(args, public_.c_str()).data(), name_, inheritedFd);
    }
    int exec(std::span<const std::string> args) const { return exec(args, public_.c_str()); }

    template <typename Edit> int editOutput(char *const argv[], std::string path, Edit update) const {
        GeneratedFile output(std::move(path));
        const int status = exitStatus(run(argv));
        if (status == 0) output.edit(name_, update);
        return status;
    }

  private:
    static std::vector<char *> command(const std::span<const std::string> &args, const char *argv0) {
        std::vector<char *> command;
        command.reserve(args.size() + 2);
        command.push_back(const_cast<char *>(argv0));
        for (const auto &arg : args) command.push_back(const_cast<char *>(arg.c_str()));
        command.push_back(nullptr);
        return command;
    }

    std::string name_;
    std::string public_;
    std::string wrapped_;
};

template <typename Main> int wrapperMain(const char *name, Main main) {
    try {
        return main(Tool(name));
    } catch (const std::exception &error) {
        std::cerr << name << " wrapper: error: " << error.what() << '\n';
        return 1;
    }
}

} // namespace cudaWrapper
