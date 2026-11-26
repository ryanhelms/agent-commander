#!/usr/bin/env python3
"""Build local self-hosted relay archives for Linux from Commander's pinned SDK."""
import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile


ROOT = Path(__file__).resolve().parents[1]
ARCHITECTURES = ("amd64", "arm64")
CHANNEL = ROOT / "dist/relay"
MODULES = ("agent-acp.local/sdks/go", "agent-acp.local/transport")
ASSETS = ("README.md", "design/RELAY-DEPLOYMENT.md", "design/verification/copilotkit-live/hosted-client.mjs",
          "packaging/relay/alerts.yml", "packaging/relay/alerts.test.yml")


def digest(path: Path) -> str:
    sha = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            sha.update(block)
    return sha.hexdigest()


def module_pins() -> tuple[dict[str, str], dict[tuple[str, str], str]]:
    module_file = json.loads(subprocess.check_output(["go", "mod", "edit", "-json"], cwd=ROOT))
    versions = {item["Path"]: item["Version"] for item in module_file["Require"]}
    sums = {(name, version): checksum for name, version, checksum in
            (line.split() for line in (ROOT / "go.sum").read_text().splitlines() if line.strip())}
    return {name: versions[name] for name in MODULES}, sums


LOCAL_MODULE = "agentcommander.network/hostkit"
LOCAL_PATH = "./multiplayer/hostkit"


def verify_binary(binary: Path, arch: str, pins: dict[str, str], sums: dict[tuple[str, str], str]) -> None:
    # Tabular build metadata works on every Go toolchain supported by Commander.
    output = subprocess.check_output(["go", "version", "-m", str(binary)], text=True)
    rows = [line.strip().split("\t") for line in output.splitlines()]
    dependencies = {}
    local = False
    for row in rows:
        # The hostkit module lives in this repository, so it has no checksum.
        if row[0] == "dep" and row[1] == LOCAL_MODULE and len(row) == 3:
            local = True
            continue
        if row[0] == "=>":
            if local and row[1:] == [LOCAL_PATH, "(devel)"]:
                local = False
                continue
            raise ValueError(f"{arch} relay binary contains a module replacement")
        local = False
        if row[0] != "dep":
            continue
        if len(row) != 4:
            raise ValueError(f"{arch} relay binary contains a dependency without a checksum")
        _, name, version, checksum = row
        if name in dependencies or sums.get((name, version)) != checksum:
            raise ValueError(f"{arch} relay binary has no matching go.sum entry for {name} {version}")
        dependencies[name] = version
    for name, version in pins.items():
        if dependencies.get(name) != version:
            raise ValueError(f"{arch} relay binary does not contain the pinned {name} {version} checksum")
    if (["path", "agentcommander/cmd/agentctl"] not in rows
            or any(["build", flag] not in rows for flag in ("GOOS=linux", f"GOARCH={arch}", "CGO_ENABLED=0"))):
        raise ValueError(f"archive does not contain a Linux {arch} agentctl release build")


def archive_relay(output: Path, binary: Path) -> None:
    files = {"agentctl": (binary, 0o755), **{name: (ROOT / name, 0o644) for name in ASSETS}}
    with output.open("wb") as raw, gzip.GzipFile(filename="", fileobj=raw, mode="wb", mtime=0) as compressed:
        with tarfile.open(fileobj=compressed, mode="w") as bundle:
            for name, (source, mode) in files.items():
                item = tarfile.TarInfo(name)
                item.mode = mode
                item.size = source.stat().st_size
                with source.open("rb") as stream:
                    bundle.addfile(item, stream)


def verify_release(output: Path, standalone: Path | None, work: Path,
                   pins: dict[str, str], sums: dict[tuple[str, str], str]) -> None:
    archives = {arch: output / f"agent-commander-relay-linux-{arch}.tar.gz" for arch in ARCHITECTURES}
    checksums = "".join(f"{digest(archive)}  {archive.name}\n" for archive in archives.values())
    if (output / "SHA256SUMS").read_text() != checksums:
        raise ValueError(f"SHA256SUMS does not match both relay archives in {output}")
    for arch, archive in archives.items():
        with tarfile.open(archive, "r:gz") as bundle:
            names = bundle.getnames()
            if len(names) != len(ASSETS) + 1 or set(names) != {"agentctl", *ASSETS}:
                raise ValueError(f"unexpected archive members in {archive.name}")
            for name in names:
                member = bundle.getmember(name)
                if not member.isfile() or member.mode != (0o755 if name == "agentctl" else 0o644):
                    raise ValueError(f"unexpected archive member type or mode for {name}")
            binary = work / f"check-{arch}"
            with bundle.extractfile("agentctl") as source, binary.open("wb") as target:
                shutil.copyfileobj(source, target)
        verify_binary(binary, arch, pins, sums)
        if standalone is not None:
            installed = standalone / f"agentctl-linux-{arch}"
            if not os.access(installed, os.X_OK) or digest(binary) != digest(installed):
                raise ValueError(f"{installed} must be executable and match its archive member")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sdk_release", type=Path, nargs="?", help="optional pinned SDK release directory override")
    parser.add_argument("--output", type=Path, default=CHANNEL)
    parser.add_argument("--verify", action="store_true", help="check existing archives and their embedded release pins")
    args = parser.parse_args()
    output = args.output.resolve()
    pins, sums = module_pins()
    standalone = ROOT / "dist" if output == CHANNEL else None
    if args.verify:
        if args.sdk_release:
            parser.error("--verify reads release pins from go.mod and go.sum")
        with tempfile.TemporaryDirectory(prefix="commander-relay-verify-") as temp:
            verify_release(output, standalone, Path(temp), pins, sums)
        print(f"Verified Linux amd64 and arm64 relay archives against go.sum and release pins {pins}")
        return
    output.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix=".build-", dir=output) as directory:
        staging = Path(directory)
        archives = []
        checksums = []
        for architecture in ARCHITECTURES:
            binary = staging / f"agentctl-linux-{architecture}"
            env = os.environ | {"GOOS": "linux", "GOARCH": architecture, "CGO_ENABLED": "0"}
            subprocess.run(
                [sys.executable, str(ROOT / "packaging" / "go-with-sdk.py"),
                 *(["--release", str(args.sdk_release.resolve())] if args.sdk_release else []),
                 "build", "-trimpath", "-buildvcs=false", "-o", str(binary), "./cmd/agentctl"],
                cwd=ROOT, env=env, check=True,
            )
            archive = staging / f"agent-commander-relay-linux-{architecture}.tar.gz"
            archive_relay(archive, binary)
            checksums.append(f"{digest(archive)}  {archive.name}")
            archives.append(archive)
        manifest = staging / "SHA256SUMS"
        manifest.write_text("\n".join(checksums) + "\n", encoding="utf-8")
        verify_release(staging, staging, staging, pins, sums)
        if standalone is not None:
            for arch in ARCHITECTURES:
                binary = staging / f"agentctl-linux-{arch}"
                binary.replace(standalone / binary.name)
        for artifact in (*archives, manifest):
            destination = output / artifact.name
            artifact.replace(destination)
            print(destination)


if __name__ == "__main__":
    main()
