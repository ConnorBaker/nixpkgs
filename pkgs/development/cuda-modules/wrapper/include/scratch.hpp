#pragma once

#include "files.hpp"

#include <charconv>
#include <filesystem>
#include <iostream>
#include <sys/file.h>

namespace cudaWrapper {

namespace fs = std::filesystem;

// FNV-1a with NUL separators. The offset, multiplier and byte order are fixed
// so names don't depend on the wrapper's C++ library or host architecture.
class StableId {
  public:
    explicit StableId(std::string_view cwd) { add(cwd); }

    void add(std::string_view value) {
        for (unsigned char c : value) hash_ = (hash_ ^ c) * 1099511628211ULL;
        hash_ *= 1099511628211ULL;
    }

    std::string finish() const {
        char digits[16];
        const auto end = std::to_chars(digits, digits + sizeof(digits), hash_, 16).ptr;
        return std::string(digits + sizeof(digits) - end, '0').append(digits, end);
    }

  private:
    std::uint64_t hash_ = 14695981039346656037ULL;
};

class ScratchDirectory {
  public:
    ScratchDirectory(fs::path path, std::string_view tool)
        : tool_(tool), path_(std::move(path)), lock_(acquire(path_)) {}
    ScratchDirectory(const ScratchDirectory &) = delete;
    ScratchDirectory &operator=(const ScratchDirectory &) = delete;
    ~ScratchDirectory() {
        if (!lock_) return;

        // Drop our reference and try an independent lock. A tool subprocess
        // or the next invocation may still own the directory.
        const FileDescriptor cleanup(openat(lock_.get(), ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC));
        lock_.close();
        struct stat opened {}, current {};
        if (!cleanup || flock(cleanup.get(), LOCK_EX | LOCK_NB) != 0 || fstat(cleanup.get(), &opened) != 0 ||
            lstat(path_.c_str(), &current) != 0 || !sameFile(opened, current))
            return;

        std::error_code error;
        fs::remove_all(path_, error);
        if (error) std::cerr << tool_ << " wrapper: cannot remove " << path_ << ": " << error.message() << '\n';
    }

    explicit operator bool() const { return static_cast<bool>(lock_); }
    int descriptor() const { return lock_.get(); }

  private:
    static constexpr char marker[] = ".nix-cuda-wrapper";

    // Clean only directories previously marked by the wrapper. Inspect and
    // remove their contents relative to the locked directory descriptor.
    static bool prepare(const FileDescriptor &dir) {
        const auto contents = descriptorPath(dir);
        struct stat owner {};
        std::error_code error;
        if (fstatat(dir.get(), marker, &owner, AT_SYMLINK_NOFOLLOW) != 0) {
            if (errno != ENOENT || !fs::is_empty(contents, error) || error) return false;
            const FileDescriptor created(openat(dir.get(), marker, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0600));
            return static_cast<bool>(created);
        }
        if (!S_ISREG(owner.st_mode) || owner.st_uid != geteuid() || owner.st_nlink != 1 || owner.st_size != 0)
            return false;

        for (fs::directory_iterator entry(contents, error), end; !error && entry != end; entry.increment(error)) {
            if (entry->path().filename() != marker) fs::remove_all(entry->path(), error);
            if (error) return false;
        }
        return !error;
    }

    // Concurrent identical invocations need the same path for debug info but
    // must never share the files inside it. Verify that the locked directory
    // is still at this path after waiting for an earlier wrapper to clean up.
    static FileDescriptor acquire(const fs::path &path) {
        for (;;) {
            if (mkdir(path.c_str(), 0700) != 0 && errno != EEXIST) return FileDescriptor();
            FileDescriptor fd(open(path.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
            if (!fd) {
                if (errno == ENOENT) continue;
                return FileDescriptor();
            }
            struct stat opened {}, current {};
            if (fstat(fd.get(), &opened) != 0 || opened.st_uid != geteuid() || (opened.st_mode & 0777) != 0700 ||
                flock(fd.get(), LOCK_EX) != 0) {
                return FileDescriptor();
            }
            const int found = lstat(path.c_str(), &current);
            if (found == 0 && sameFile(current, opened)) {
                if (prepare(fd)) return fd;
                return FileDescriptor();
            }
            if (found != 0 && errno != ENOENT) return FileDescriptor();
        }
    }

    std::string tool_;
    fs::path path_;
    FileDescriptor lock_;
};

} // namespace cudaWrapper
