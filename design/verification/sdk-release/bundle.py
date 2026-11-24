#!/usr/bin/env python3
"""Archive the independently installable SDK, transport and consumer verifier."""
import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile

from verify import check_manifest


HERE = Path(__file__).resolve().parent
SDK = "agent-acp.local/sdks/go"
TRANSPORT = "agent-acp.local/transport"


def bundle(release: Path, destination: Path) -> None:
    manifest = check_manifest(release)
    version = manifest["version"]
    if manifest["goModule"] != SDK or release.name != f"agent-acp-{version}":
        raise ValueError("expected a versioned Agent ACP SDK release directory")
    sdk_mod = release / "go" / SDK / "@v" / f"v{version}.mod"
    metadata = json.loads(subprocess.check_output(["go", "mod", "edit", "-json", sdk_mod]))
    transport_pin = next(r["Version"] for r in metadata["Require"] if r["Path"] == TRANSPORT)
    transport_release = release.parent / f"agent-acp-transport-{transport_pin.removeprefix('v')}"
    transport_manifest = check_manifest(transport_release)
    if (transport_manifest["goModule"], "v" + transport_manifest["version"]) != (TRANSPORT, transport_pin):
        raise ValueError("transport manifest does not match the SDK dependency")

    files = {}
    for directory, metadata in ((release, manifest), (transport_release, transport_manifest)):
        raw_manifest = (directory / "manifest.json").read_bytes()
        if json.loads(raw_manifest) != metadata:
            raise ValueError(f"release manifest changed during packaging: {directory.name}")
        files[f"{directory.name}/manifest.json"] = raw_manifest
        for name, digest in metadata["sha256"].items():
            data = (directory / name).read_bytes()
            if hashlib.sha256(data).hexdigest() != digest:
                raise ValueError(f"release artifact changed during packaging: {directory.name}/{name}")
            files[f"{directory.name}/{name}"] = data
    for name in ("verify.py", "consumer/types.mts", "consumer/contract.test.mjs", "consumer/test_contract.py"):
        files[f"verification/{name}"] = (HERE / name).read_bytes()
    files["README.md"] = f"""# Agent ACP SDK {version}

This bundle contains the local Go module proxy, TypeScript tarball, Python
wheel, Go transport release and consumer conformance fixtures. Both release
directories contain the original upstream checksums from the local build.

Run the consumer verifier with Go, Node.js, npm and Python available.

```sh
python3 -B verification/verify.py --consumer-only {release.name}
```

The verifier resolves public dependencies from the usual tool caches and
registries. On an offline host, supply a Go download cache, an npm cache
containing TypeScript 5.9.3 and the SDK's public dependencies, and a wheelhouse
for Python. Set `GOPROXY=off`, `GOSUMDB=off`, `GOTOOLCHAIN=local`,
`npm_config_offline=true`, `PIP_NO_INDEX=1` and `PIP_FIND_LINKS` to the
wheelhouse path for an offline check.
""".encode()

    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".sdk-bundle-", dir=destination.parent) as tmp:
        archive = Path(tmp) / destination.name
        with archive.open("wb") as raw, gzip.GzipFile(filename="", fileobj=raw, mode="wb", mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode="w") as tar:
                for name, data in sorted(files.items()):
                    entry = tarfile.TarInfo(name)
                    entry.mode = 0o644
                    entry.size = len(data)
                    tar.addfile(entry, io.BytesIO(data))
        data = archive.read_bytes()
        try:
            destination.hardlink_to(archive)
        except FileExistsError:
            if destination.read_bytes() != data:
                raise FileExistsError(f"{destination} already contains a different archive")
    print(f"{hashlib.sha256(data).hexdigest()}  {destination.name}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sdk_release", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    bundle(args.sdk_release.resolve(), args.destination.resolve())


if __name__ == "__main__":
    main()
