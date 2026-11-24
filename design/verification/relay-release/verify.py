"""Rehearse a relay upgrade and rollback using two trusted Linux release directories."""

import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile


ROOT = Path(__file__).resolve().parents[3]
ARCHITECTURES = ("amd64", "arm64")


def extract_relay(release: Path, arch: str, target: Path) -> None:
    name = f"agent-commander-relay-linux-{arch}.tar.gz"
    manifest = (release / "SHA256SUMS").read_text().splitlines()
    expected = [digest for digest, file in (line.split() for line in manifest) if file == name]
    with (release / name).open("rb") as archive:
        if expected != [hashlib.file_digest(archive, "sha256").hexdigest()]:
            raise ValueError(f"missing, ambiguous or incorrect SHA-256 for {release / name}")
        archive.seek(0)
        with tarfile.open(fileobj=archive) as bundle:
            binaries = [member for member in bundle.getmembers() if member.name == "agentctl"]
            if len(binaries) != 1 or not binaries[0].isfile() or binaries[0].mode != 0o755:
                raise ValueError(f"invalid executable in {release / name}")
            with bundle.extractfile(binaries[0]) as source, target.open("xb") as dest:
                shutil.copyfileobj(source, dest)
    target.chmod(0o755)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("previous", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("--arch", choices=ARCHITECTURES, action="append", help="default: both architectures")
    args = parser.parse_args()
    # The fixture runs natively in Docker Desktop's Linux VM. Docker must
    # support executing the selected relay architecture as a child process.
    host_arch = subprocess.check_output(["go", "env", "GOHOSTARCH"], text=True).strip()
    platform = "linux/" + host_arch
    with tempfile.TemporaryDirectory(prefix="commander-relay-release-") as temp:
        work = Path(temp)
        harness = work / "rehearsal"
        env = os.environ | {"CGO_ENABLED": "0", "GOOS": "linux", "GOARCH": host_arch, "GOWORK": "off", "GOFLAGS": ""}
        subprocess.run(
            ["go", "build", "-trimpath", "-buildvcs=false", "-o", harness, "./design/verification/relay-release"],
            cwd=ROOT, env=env, check=True,
        )
        for arch in dict.fromkeys(args.arch or ARCHITECTURES):
            stage = work / arch
            stage.mkdir()
            extract_relay(args.previous, arch, stage / "previous")
            extract_relay(args.candidate, arch, stage / "candidate")
            shutil.copy2(harness, stage / "rehearsal")
            (stage / "Dockerfile").write_text(
                'FROM scratch\nCOPY previous candidate rehearsal /\nUSER 65532:65532\n'
                'ENTRYPOINT ["/rehearsal", "/previous", "/candidate"]\n'
            )
            iid = work / f"{arch}.image"
            subprocess.run(
                ["docker", "build", "--network=none", "--provenance=false", "--platform", platform,
                 "--iidfile", iid, stage], check=True, timeout=120,
            )
            print(f"Rehearsing Linux {arch} relay packages", flush=True)
            subprocess.run(
                ["docker", "run", "--rm", "--network=none", "--read-only", "--platform", platform,
                 "--tmpfs", "/tmp:rw,nosuid,nodev,mode=1777", iid.read_text().strip()],
                check=True, timeout=75,
            )


if __name__ == "__main__":
    main()
