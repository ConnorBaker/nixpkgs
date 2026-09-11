"""Install the executable artifacts in the build's current CMake file API reply."""

import json
import os
import re
import shutil
import sys
from pathlib import Path


def discover(build: Path) -> dict[str, str]:
    reply = build / ".cmake/api/v1/reply"
    indexes = sorted(reply.glob("index-*.json"))
    if not indexes:
        raise ValueError("CMake did not answer the file API query")
    index = json.loads(indexes[-1].read_text())
    model = json.loads((reply / index["reply"]["codemodel-v2"]["jsonFile"]).read_text())
    configurations = model["configurations"]
    if len(configurations) != 1:
        configurations = [c for c in configurations if c["name"] == "Release"]
    if len(configurations) != 1:
        raise ValueError("expected one build configuration or a Release configuration")
    programs = {}
    for entry in configurations[0].get("targets", []):
        target = json.loads((reply / entry["jsonFile"]).read_text())
        if target["type"] != "EXECUTABLE":
            continue
        # OUTPUT_NAME can differ from the target name. Imported tools are absent from the
        # codemodel's target list, unlike a glob over every target JSON file.
        name = target["nameOnDisk"]
        if not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.+\-]*", name):
            raise ValueError(f"unsupported executable filename: {name!r}")
        artifacts = [
            a["path"] for a in target["artifacts"] if Path(a["path"]).name == name
        ]
        if len(artifacts) != 1:
            raise ValueError(
                f"expected one executable artifact for {name}: {artifacts}"
            )
        artifact = Path(artifacts[0])
        if artifact.is_absolute() or ".." in artifact.parts:
            raise ValueError(f"executable is outside the build directory: {artifact}")
        if name in programs:
            raise ValueError(f"two targets install the same executable name: {name}")
        programs[name] = artifact.as_posix()
    if not programs:
        raise ValueError("CMake configured no executable targets")
    return dict(sorted(programs.items()))


def install(build: Path, output: Path) -> None:
    programs = discover(build)
    binary_dir = output / "bin"
    binary_dir.mkdir(parents=True, exist_ok=True)
    for name, artifact in programs.items():
        source = build / artifact
        if not source.is_file() or not os.access(source, os.X_OK):
            raise ValueError(
                f"CMake declared {name}, but no executable was built at {source}"
            )
        shutil.copy2(source, binary_dir / name)


if __name__ == "__main__":
    try:
        build, output = sys.argv[1:]
        install(Path(build), Path(output))
    except (ValueError, KeyError, OSError) as error:
        sys.exit(str(error))
