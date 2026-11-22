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
#include <system_error>
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

class SignalMask {
  public:
    SignalMask() {
        sigemptyset(&signals_);
        for (const int sig : {SIGHUP, SIGINT, SIGQUIT, SIGTERM, SIGUSR1, SIGUSR2, SIGCHLD})
            sigaddset(&signals_, sig);
        if (sigprocmask(SIG_BLOCK, &signals_, &original_) != 0)
            throw std::system_error(errno, std::generic_category(), "block signals");

        // An inherited SIG_IGN or SA_NOCLDWAIT would let the kernel reap the child.
        struct sigaction action {};
        action.sa_handler = SIG_DFL;
        sigemptyset(&action.sa_mask);
        if (sigaction(SIGCHLD, &action, &originalChild_) != 0) {
            const int error = errno;
            restoreMask();
            throw std::system_error(error, std::generic_category(), "reset SIGCHLD");
        }
    }

    SignalMask(const SignalMask &) = delete;
    SignalMask &operator=(const SignalMask &) = delete;
    ~SignalMask() { restore(); }

    int restore() const {
        const int action = sigaction(SIGCHLD, &originalChild_, nullptr);
        const int mask = restoreMask();
        return action != 0 ? action : mask;
    }

    int wait(siginfo_t &info) const { return sigwaitinfo(&signals_, &info); }

  private:
    int restoreMask() const { return sigprocmask(SIG_SETMASK, &original_, nullptr); }

    sigset_t signals_;
    sigset_t original_;
    struct sigaction originalChild_;
};

// Runs the wrapped program with argv and returns its wait status.
inline int run(const std::string &program, char *const argv[], std::string_view wrapper, int inheritedFd = -1) {
    const SignalMask signals;
    // In the foreground of a terminal, the program stays in the wrapper's process group, so that it receives the signals
    // from the terminal itself and the wrapper doesn't forward them. Otherwise the program gets a process group of its own,
    // so that a signal sent to the wrapper's process group (e.g. by timeout) can be forwarded to the whole tool tree.
    const bool foreground = inForeground();
    const pid_t parent = getpid();
    const pid_t child = fork();
    if (child < 0) throw std::system_error(errno, std::generic_category(), "fork");
    if (child == 0) {
        // Don't outlive the wrapper.
        if (prctl(PR_SET_PDEATHSIG, SIGKILL) != 0 || getppid() != parent) _exit(127);
        if (!foreground && setpgid(0, 0) != 0) _exit(127);
        // Preserve the caller's standard descriptors even if the lease used a closed one.
        if (inheritedFd >= 0 && fcntl(inheritedFd, F_DUPFD, STDERR_FILENO + 1) < 0) {
            std::cerr << wrapper << " wrapper: error: cannot inherit descriptor: " << std::strerror(errno) << '\n';
            _exit(127);
        }
        if (signals.restore() != 0) _exit(127);
        _exit(exec(program, argv, wrapper));
    }

    // Either process can run first. Assign the group before forwarding a pending signal.
    if (!foreground) static_cast<void>(setpgid(child, child));
    for (;;) {
        int status = 0;
        const pid_t finished = waitpid(child, &status, WNOHANG);
        if (finished == child) return status;
        if (finished < 0) {
            if (errno == EINTR) continue;
            throw std::system_error(errno, std::generic_category(), "waitpid");
        }

        siginfo_t info;
        const int signal = signals.wait(info);
        if (signal < 0) {
            if (errno == EINTR) continue;
            throw std::system_error(errno, std::generic_category(), "sigwaitinfo");
        }
        if (signal != SIGCHLD && (!foreground || info.si_code != SI_KERNEL))
            kill(foreground ? child : -child, signal);
    }
}

// Reproduce signal termination after the caller has cleaned up.
inline int exitStatus(int status) {
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    const int signal = WTERMSIG(status);
    static_cast<void>(std::signal(signal, SIG_DFL));
    sigset_t unblocked;
    sigemptyset(&unblocked);
    sigaddset(&unblocked, signal);
    sigprocmask(SIG_UNBLOCK, &unblocked, nullptr);
    static_cast<void>(std::raise(signal));
    return 128 + signal;
}

// A public tool and its vendor executable installed beside it.
class Tool {
  public:
    explicit Tool(const char *name) {
        const auto self = executable();
        name_ = name ? name : self.filename().native();
        const auto bin = self.parent_path();
        public_ = bin / name_;
        wrapped_ = bin / ("." + name_ + "-wrapped");
    }

    std::string_view name() const { return name_; }

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
        std::cerr << (name ? name : "CUDA tool") << " wrapper: error: " << error.what() << '\n';
        return 1;
    }
}

// A single adapter can be copied to multiple public tool paths.
template <typename Main> int wrapperMain(Main main) {
    return wrapperMain(nullptr, main);
}

} // namespace cudaWrapper
