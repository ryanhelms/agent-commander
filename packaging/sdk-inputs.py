#!/usr/bin/env python3
"""Stage the public Go module proxy files pinned by go.mod."""

import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
from urllib.request import urlopen


ROOT = Path(__file__).resolve().parents[1]
SDK_ROOT = ROOT / "dist" / "sdk"
ASSET = "go-build-inputs.tar.gz"
PUBLIC_REPOSITORY = "ryanhelms/agent-commander"
MODULE_DIRECTORIES = {
    "agent-acp.local/sdks/go": "agent-acp",
    "agent-acp.local/transport": "agent-acp-transport",
}


def inputs():
    module = json.loads(subprocess.check_output(["go", "mod", "edit", "-json"], cwd=ROOT))
    requirements = {item["Path"]: item["Version"] for item in module["Require"]}
    versions = [requirements[name] for name in MODULE_DIRECTORIES]
    files = {
        f"{folder}-{requirements[name][1:]}/go/{name}/@v/{requirements[name]}{suffix}"
        for name, folder in MODULE_DIRECTORIES.items()
        for suffix in (".info", ".mod", ".zip")
    }
    return f"go-inputs-{versions[0]}-transport-{versions[1]}", files


def unpack(archive, expected):
    with tarfile.open(archive, "r:gz") as bundle:
        members = bundle.getmembers()
        if len(members) != len(expected) or {item.name for item in members} != expected:
            raise ValueError("Unexpected members in the Go build input archive")
        if any(not item.isfile() for item in members):
            raise ValueError("Go build input archive must contain only regular files")
        for item in members:
            destination = SDK_ROOT / item.name
            destination.parent.mkdir(parents=True, exist_ok=True)
            with bundle.extractfile(item) as source, destination.open("wb") as target:
                shutil.copyfileobj(source, target)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("tag")
    commands.add_parser("pack").add_argument("archive", type=Path)
    commands.add_parser("fetch").add_argument("repository", nargs="?", default=PUBLIC_REPOSITORY)
    args = parser.parse_args()
    tag, expected = inputs()
    if args.command == "tag":
        print(tag)
    elif args.command == "pack":
        for name in expected:
            if not (SDK_ROOT / name).is_file():
                parser.error(f"Missing pinned Go proxy file: {name}")
        with tarfile.open(args.archive, "w:gz") as bundle:
            for name in sorted(expected):
                bundle.add(SDK_ROOT / name, arcname=name, recursive=False)
    else:
        with tempfile.TemporaryDirectory(prefix="commander-go-inputs-") as folder:
            url = f"https://github.com/{args.repository}/releases/download/{tag}/{ASSET}"
            archive = Path(folder) / ASSET
            with urlopen(url, timeout=60) as response, archive.open("wb") as target:
                shutil.copyfileobj(response, target)
            unpack(archive, expected)


if __name__ == "__main__":
    main()
