#pragma once

#include <optional>
#include <ranges>
#include <stdexcept>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace cudaWrapper {

// BUILD_PATH_PREFIX_MAP uses target=source entries and gives the last matching
// entry priority. Check a whole path component when matching source prefixes.
class PathPrefixMap {
  public:
    explicit PathPrefixMap(std::string_view encoded) {
        for (const auto item : std::views::split(encoded, ':')) {
            if (item.empty()) continue;
            const std::string_view pair(item.begin(), item.end());
            const auto equals = pair.find('=');
            if (equals == std::string_view::npos || pair.find('=', equals + 1) != std::string_view::npos)
                throw invalid();
            prefixes_.emplace_back(decode(pair.substr(0, equals)), decode(pair.substr(equals + 1)));
        }
    }

    bool empty() const { return prefixes_.empty(); }

    std::optional<std::string> remap(std::string_view path) const {
        for (const auto &[target, source] : prefixes_ | std::views::reverse) {
            if (!path.starts_with(source)) continue;
            const auto suffix = path.substr(source.size());
            if (source.empty() || source.back() == '/' || suffix.empty() || suffix.front() == '/')
                return target + std::string(suffix);
        }
        return std::nullopt;
    }

  private:
    static std::runtime_error invalid() { return std::runtime_error("invalid BUILD_PATH_PREFIX_MAP"); }

    static std::string decode(std::string_view part) {
        std::string decoded;
        for (std::size_t i = 0; i < part.size(); ++i) {
            if (part[i] != '%') {
                decoded += part[i];
                continue;
            }
            if (++i == part.size()) throw invalid();
            switch (part[i]) {
            case '#': decoded += '%'; break;
            case '+': decoded += '='; break;
            case '.': decoded += ':'; break;
            default: throw invalid();
            }
        }
        return decoded;
    }

    std::vector<std::pair<std::string, std::string>> prefixes_;
};

} // namespace cudaWrapper
