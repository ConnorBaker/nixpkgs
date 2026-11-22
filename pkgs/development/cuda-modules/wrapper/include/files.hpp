#pragma once

#include <algorithm>
#include <cerrno>
#include <cstdint>
#include <cstring>
#include <fcntl.h>
#include <optional>
#include <span>
#include <stdexcept>
#include <string>
#include <string_view>
#include <sys/stat.h>
#include <unistd.h>
#include <utility>
#include <vector>

namespace cudaWrapper {

class FileDescriptor {
  public:
    explicit FileDescriptor(int fd = -1) : fd_(fd) {}
    FileDescriptor(const FileDescriptor &) = delete;
    FileDescriptor &operator=(const FileDescriptor &) = delete;
    FileDescriptor(FileDescriptor &&other) noexcept : fd_(other.release()) {}
    ~FileDescriptor() { close(); }

    int get() const { return fd_; }
    explicit operator bool() const { return fd_ >= 0; }
    int release() { return std::exchange(fd_, -1); }

    int close() {
        if (fd_ < 0) return 0;
        return ::close(release());
    }

  private:
    int fd_;
};

inline void checkFileRange(std::uint64_t size, std::uint64_t offset, std::uint64_t count) {
    if (offset > size || count > size - offset) throw std::runtime_error("byte range exceeds the artifact");
}

inline bool sameFile(const struct stat &a, const struct stat &b) {
    return a.st_dev == b.st_dev && a.st_ino == b.st_ino;
}

inline bool sameFileVersion(const struct stat &a, const struct stat &b) {
    const auto sameTime = [](const timespec &x, const timespec &y) {
        return x.tv_sec == y.tv_sec && x.tv_nsec == y.tv_nsec;
    };
    return sameFile(a, b) && sameTime(a.st_mtim, b.st_mtim) && sameTime(a.st_ctim, b.st_ctim);
}

inline std::string readOptionsFile(const std::string &path, std::size_t &bytesRemaining) {
    struct stat info {};
    const auto notRegular = [&] { return std::runtime_error("options file " + path + " is missing or not a regular file"); };
    if (stat(path.c_str(), &info) != 0 || !S_ISREG(info.st_mode)) throw notRegular();
    // Avoid blocking if another program replaces the file with a pipe after stat.
    const FileDescriptor fd(open(path.c_str(), O_RDONLY | O_NONBLOCK | O_CLOEXEC));
    const auto unreadable = [&] { return std::runtime_error("cannot read options file " + path); };
    if (!fd || fstat(fd.get(), &info) != 0) throw unreadable();
    if (!S_ISREG(info.st_mode)) throw notRegular();
    if (static_cast<std::uintmax_t>(info.st_size) > bytesRemaining)
        throw std::runtime_error("options files exceed the inspection size limit");
    std::string contents(static_cast<std::size_t>(info.st_size), '\0');
    for (std::size_t offset = 0; offset < contents.size();) {
        const auto got = read(fd.get(), contents.data() + offset, contents.size() - offset);
        if (got < 0 && errno == EINTR) continue;
        if (got <= 0) throw unreadable();
        offset += static_cast<std::size_t>(got);
    }
    bytesRemaining -= contents.size();
    return contents;
}

// Open an output produced by the tool, and verify its identity on the
// descriptor used for in-place edits. Delete only the observed output on
// edit failure, after checking that the path still refers to the same file.
class GeneratedFile {
  public:
    explicit GeneratedFile(std::string path) : path_(std::move(path)) {
        struct stat info {};
        if (stat(path_.c_str(), &info) == 0) {
            if (!S_ISREG(info.st_mode)) throw std::runtime_error(path_ + " is not a regular file");
            before_ = info;
        }
    }

    template <typename Edit> void edit(std::string_view tool, Edit update) {
        struct stat after {};
        if (stat(path_.c_str(), &after) != 0 || !S_ISREG(after.st_mode) ||
            (before_ && sameFileVersion(*before_, after)))
            throw std::runtime_error(std::string(tool) + " didn't write " + path_);

        bool openedOutput = false;
        try {
            FileDescriptor fd(open(path_.c_str(), O_RDWR | O_NONBLOCK | O_CLOEXEC));
            if (!fd) fail("cannot open");
            struct stat opened {};
            if (fstat(fd.get(), &opened) != 0) fail("cannot inspect");
            if (!S_ISREG(opened.st_mode) || !sameFileVersion(after, opened))
                throw std::runtime_error(path_ + " changed before it could be opened");
            openedOutput = true;
            Contents contents(fd.get(), opened.st_size, path_);
            update(contents);
            if (fd.close() != 0 && errno != EINTR) fail("cannot write");
        } catch (...) {
            struct stat current {};
            if (stat(path_.c_str(), &current) == 0 &&
                (openedOutput ? sameFile(after, current) : sameFileVersion(after, current)))
                static_cast<void>(unlink(path_.c_str()));
            throw;
        }
    }

  private:
    class Contents {
      public:
        Contents(int fd, std::uint64_t size, const std::string &path) : fd_(fd), size_(size), path_(path) {}
        std::uint64_t size() const { return size_; }

        std::vector<char> read(std::uint64_t off, std::uint64_t n) const {
            checkFileRange(size_, off, n);
            std::vector<char> bytes(n);
            for (std::uint64_t done = 0; done < n;) {
                const ssize_t got = pread(fd_, bytes.data() + done, n - done, static_cast<off_t>(off + done));
                if (got < 0 && errno == EINTR) continue;
                if (got <= 0) fileError("cannot read", path_);
                done += static_cast<std::uint64_t>(got);
            }
            return bytes;
        }

        void write(std::uint64_t off, std::span<const char> bytes) {
            checkFileRange(size_, off, bytes.size());
            writeAt(off, bytes);
        }

      private:
        void writeAt(std::uint64_t off, std::span<const char> bytes) {
            for (std::uint64_t done = 0; done < bytes.size();) {
                const ssize_t put = pwrite(fd_, bytes.data() + done, bytes.size() - done, static_cast<off_t>(off + done));
                if (put < 0 && errno == EINTR) continue;
                if (put <= 0) fileError("cannot write", path_);
                done += static_cast<std::uint64_t>(put);
            }
        }

        int fd_;
        std::uint64_t size_;
        const std::string &path_;
    };

    [[noreturn]] static void fileError(std::string_view action, const std::string &path) {
        throw std::runtime_error(std::string(action) + " " + path + ": " + std::strerror(errno));
    }

    [[noreturn]] void fail(std::string_view action) const { fileError(action, path_); }

    std::string path_;
    std::optional<struct stat> before_;
};

// The same sized byte-access interface for artifacts returned by library APIs.
class MemoryBuffer {
  public:
    explicit MemoryBuffer(std::span<char> bytes) : bytes_(bytes) {}
    std::uint64_t size() const { return bytes_.size(); }

    std::vector<char> read(std::uint64_t off, std::uint64_t n) const {
        checkFileRange(size(), off, n);
        const auto part = bytes_.subspan(off, n);
        return {part.begin(), part.end()};
    }

    void write(std::uint64_t off, std::span<const char> data) {
        checkFileRange(size(), off, data.size());
        std::ranges::copy(data, bytes_.subspan(off, data.size()).begin());
    }

  private:
    std::span<char> bytes_;
};

} // namespace cudaWrapper
