#!/usr/bin/env nix-shell
#!nix-shell -i python -p python3 nix git

# TODO(@connorbaker): This could be sped up by using async requests and/or
#   multiprocessing.

from pathlib import Path
import re
import urllib.request
import dataclasses
from dataclasses import dataclass
from typing import NewType, Literal, Union
import logging
import subprocess
import json
import asyncio

logging.basicConfig(
    level=logging.DEBUG,
    datefmt="%Y-%m-%dT%H:%M:%S%z",
    format="[%(asctime)s][%(levelname)s] %(message)s",
)

logger = logging.getLogger(__name__)

RepoOwner = NewType("RepoOwner", str)
RepoName = NewType("RepoName", str)
Tag = NewType("Tag", str)
SRIHash = NewType("SRIHash", str)
StorePath = NewType("StorePath", str)

AppleRepoOwner = RepoOwner("apple-oss-distributions")
MacOSRepoName = RepoName("distribution-macOS")
DeveloperToolsRepoName = RepoName("distribution-Developer_Tools")


@dataclass(frozen=True, order=True)
class Version:
    major: int
    minor: int
    patch: int

    def __str__(self) -> str:
        return f"{self.major}.{self.minor}.{self.patch}"


@dataclass(frozen=True, order=True)
class Release:
    major_release: str
    release: str
    version: Version
    projects: dict[RepoName, Tag]


class EnhancedJSONEncoder(json.JSONEncoder):
    def default(self, o):
        if isinstance(o, Version):
            return str(o)
        elif dataclasses.is_dataclass(o):
            return dataclasses.asdict(o)
        return super().default(o)


@dataclass(frozen=True, order=True)
class NixStoreEntry:
    store_path: StorePath
    hash: SRIHash


@dataclass(frozen=True, order=True)
class FetchFromGitHubArgs:
    owner: RepoOwner
    repo: RepoName
    rev: Tag
    hash: SRIHash


AppleOSSReleases = dict[Version, FetchFromGitHubArgs]


def extract_version(release: str) -> Union[None, Version]:
    """
    Extract the version from a release string.

    Releases are expected to be in the format `name x.y(.z)`, where:

    - `name` is the name of the software release,
    - `x` is the major version,
    - `y` is the minor version,
    - and `z` is an optional patch version.

    Returns a Version object or raises a ValueError if the release string is invalid.
    """
    match = re.match(
        r"^(?P<name>.+) (?P<major>\d+)\.(?P<minor>\d+)(?:\.(?P<patch>\d+))?$",
        release,
    )
    if not match:
        logger.warning(f"Invalid release string: {release}")
        return None

    name = match.group("name")
    major = int(match.group("major"))
    minor = int(match.group("minor"))
    patch = int(match.group("patch")) if match.group("patch") else 0

    ret = Version(major, minor, patch)
    logger.info(f"Extracted version {ret} for {name} from release string {release}")

    return ret


async def fetch_tags(owner: RepoOwner, name: RepoName) -> list[Tag]:
    """Fetch all tags from the repository and return them as a list."""
    logger.info(f"Fetching tags and refs from github:{owner}/{name}...")
    result = subprocess.run(
        [
            "git",
            "ls-remote",
            "--tags",
            "--refs",
            f"https://github.com/{owner}/{name}",
        ],
        capture_output=True,
    )

    match_tags = re.compile(r"^.+refs/tags/(.+)$", re.MULTILINE)
    ret = [Tag(tag) for tag in match_tags.findall(result.stdout.decode("utf-8"))]

    logger.info(f"Found {len(ret)} tags")
    return ret


async def fetch_release(
    owner: RepoOwner, name: RepoName, tag: Tag
) -> Union[None, Release]:
    """
    Fetch the release.json file from the given repository and tag and return it as a
    Release object.

    Raises a ValueError if the release.json file is invalid.
    """
    projects: dict[RepoName, Tag] = {}
    with urllib.request.urlopen(
        f"https://raw.githubusercontent.com/{owner}/{name}/{tag}/release.json"
    ) as f:
        release_json = json.load(f)
        major_release_string = release_json["major_release"]
        release_string = release_json["release"]
        version = extract_version(release_string)
        if not version:
            return None

        for project in release_json["projects"]:
            projects[RepoName(project["project"])] = Tag(project["tag"])

        return Release(
            major_release=major_release_string,
            release=release_string,
            version=version,
            projects=projects,
        )


async def nix_fetch_repo(owner: RepoOwner, name: RepoName, tag: Tag) -> NixStoreEntry:
    url = f"https://github.com/{owner}/{name}/archive/refs/tags/{tag}.tar.gz"
    logger.info(f"Adding {url} to Nix store...")
    result = subprocess.run(
        ["nix", "flake", "prefetch", "--json", url],
        capture_output=True,
    )

    parsed = json.loads(result.stdout)
    store_entry = NixStoreEntry(store_path=parsed["storePath"], hash=parsed["hash"])
    logger.info(f"Stored at {store_entry.store_path} with hash {store_entry.hash}")

    return store_entry


async def regenerate_releases(
    package_set: Literal["macOS", "DeveloperTools"], min_version: Version
) -> None:
    dist_dir = Path("distributions") / package_set
    dist_dir.mkdir(parents=True, exist_ok=True)

    repo = MacOSRepoName if package_set == "macOS" else DeveloperToolsRepoName
    for tag in await fetch_tags(AppleRepoOwner, repo):
        try:
            release = await fetch_release(AppleRepoOwner, repo, tag)
            if not release:
                logger.warning(f"Skipping {tag} since it's not a valid release")
                continue

            if release.version < min_version:
                logger.info(
                    f"Skipping {release.version} since it's less than {min_version}"
                )
                continue

            d = {}
            store_entries = await asyncio.gather(
                *[
                    nix_fetch_repo(AppleRepoOwner, project, project_tag)
                    for project, project_tag in release.projects.items()
                ]
            )
            for (project, project_tag), store_entry in zip(
                release.projects.items(), store_entries
            ):
                d[project] = FetchFromGitHubArgs(
                    owner=AppleRepoOwner,
                    repo=project,
                    rev=project_tag,
                    hash=store_entry.hash,
                )

            with open(dist_dir / f"{release.version}.json", "w") as f:
                json.dump(d, f, indent=4, sort_keys=True, cls=EnhancedJSONEncoder)
        except ValueError as e:
            logger.error(e)
            continue


async def main():
    await asyncio.gather(
        regenerate_releases("macOS", min_version=Version(10, 12, 0)),
        regenerate_releases("DeveloperTools", min_version=Version(10, 0, 0)),
    )


if __name__ == "__main__":
    asyncio.run(main())
