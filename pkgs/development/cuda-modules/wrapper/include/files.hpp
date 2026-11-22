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
#include <sys/mman.h>
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

template <typename Transfer, typename Byte>
bool transferAllAt(Transfer transfer, int fd, std::span<Byte> bytes, std::uint64_t offset) {
    while (!bytes.empty()) {
        const auto count = transfer(fd, bytes.data(), bytes.size(), static_cast<off_t>(offset));
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) {
            if (count == 0) errno = EIO;
            return false;
        }
        offset += count;
        bytes = bytes.subspan(count);
    }
    return true;
}

// Expose rewritten input as a file without leaving anything to clean up.
inline FileDescriptor anonymousInput(const char *name, std::string_view contents) {
    FileDescriptor fd(memfd_create(name, 0)); // The vendor inherits the descriptor across exec.
    if (!fd) throw std::runtime_error(std::string("cannot open ") + name + ": " + std::strerror(errno));
    if (!transferAllAt(pwrite, fd.get(), std::span(contents), 0))
        throw std::runtime_error(std::string("cannot write ") + name + ": " + std::strerror(errno));
    if (fd.get() > STDERR_FILENO) return fd;

    // A caller may have closed a standard descriptor. Keep it closed for
    // the vendor while passing the input through an independent descriptor.
    FileDescriptor input(fcntl(fd.get(), F_DUPFD, STDERR_FILENO + 1));
    if (!input) throw std::runtime_error(std::string("cannot duplicate ") + name + ": " + std::strerror(errno));
    return input;
}

inline std::string descriptorPath(const FileDescriptor &fd) {
    return "/proc/self/fd/" + std::to_string(fd.get());
}

inline void checkFileRange(std::uint64_t size, std::uint64_t offset, std::uint64_t count) {
    if (offset > size || count > size - offset) throw std::runtime_error("byte range exceeds the artifact");
}

inline bool sameFile(const struct stat &a, const struct stat &b) {
    return a.st_dev == b.st_dev && a.st_ino == b.st_ino;
}

inline bool isSpecialFile(const std::string &path) {
    struct stat info {};
    return stat(path.c_str(), &info) == 0 && !S_ISREG(info.st_mode);
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
    if (!transferAllAt(pread, fd.get(), std::span(contents), 0)) throw unreadable();
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

    template <typename Rewrite> void rewriteText(std::string_view tool, Rewrite rewrite) {
        edit(tool, [&](Contents &file) {
            const auto contents = file.read(0, file.size());
            if (const auto replacement = rewrite(std::string_view(contents.data(), contents.size())))
                file.replace(*replacement);
        });
    }

  private:
    class Contents {
      public:
        Contents(int fd, std::uint64_t size, const std::string &path) : fd_(fd), size_(size), path_(path) {}
        std::uint64_t size() const { return size_; }

        std::vector<char> read(std::uint64_t off, std::uint64_t n) const {
            checkFileRange(size_, off, n);
            std::vector<char> bytes(n);
            if (!transferAllAt(pread, fd_, std::span(bytes), off)) fileError("cannot read", path_);
            return bytes;
        }

        void write(std::uint64_t off, std::span<const char> bytes) {
            checkFileRange(size_, off, bytes.size());
            writeAt(off, bytes);
        }

        void replace(std::string_view text) {
            writeAt(0, text);
            if (text.size() != size_ && ftruncate(fd_, static_cast<off_t>(text.size())) != 0)
                fileError("cannot resize", path_);
            size_ = text.size();
        }

      private:
        void writeAt(std::uint64_t off, std::span<const char> bytes) {
            if (!transferAllAt(pwrite, fd_, bytes, off)) fileError("cannot write", path_);
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
