#!/usr/bin/env python3
"""Build and verify the universal Agent Commander macOS pilot archive."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

from changelog import version


ROOT = Path(__file__).resolve().parents[1]
DIST = ROOT / "dist"
ARCHITECTURES = {"arm64": "arm64", "x86_64": "amd64"}
EXECUTABLES = ("AgentCommander", "agentctl", "commander-network")
RESOURCES = ("AgentCommander_AgentCommander.bundle", "SwiftTerm_SwiftTerm.bundle")
MACOS_TARGET = "26.0"


def run(*args, **kwargs):
    subprocess.run(args, check=True, **kwargs)


def output(*args, **kwargs):
    return subprocess.check_output(args, text=True, **kwargs).strip()


def build_slice(stage, arch, sdk, clang, sdk_release):
    binaries = stage / arch
    binaries.mkdir()
    env = os.environ | {
        "GOOS": "darwin",
        "GOARCH": ARCHITECTURES[arch],
        "CGO_ENABLED": "1",
        "GOWORK": "off",
        "GOFLAGS": "",
        "CC": clang,
        "SDKROOT": sdk,
        "MACOSX_DEPLOYMENT_TARGET": MACOS_TARGET,
    }
    sdk_args = ("--release", sdk_release) if sdk_release else ()
    run("python3", "packaging/go-with-sdk.py", *sdk_args, "build", "-o", binaries / "agentctl",
        "./cmd/agentctl", cwd=ROOT, env=env)
    run("go", "build", "-mod=readonly", "-o", binaries / "commander-network",
        "./cmd/commander-network", cwd=ROOT / "multiplayer", env=env)

    swift = ("swift", "build", "--triple", f"{arch}-apple-macosx{MACOS_TARGET}",
             "--only-use-versions-from-resolved-file", "--jobs", "3", "-c", "release")
    run(*swift, "--product", "AgentCommander", cwd=ROOT)
    products = Path(output(*swift, "--show-bin-path", cwd=ROOT))
    shutil.copy2(products / "AgentCommander", binaries)
    for name in EXECUTABLES:
        run("lipo", binaries / name, "-verify_arch", arch)
    return products


def verify_bundle(bundle):
    run("codesign", "--verify", "--all-architectures", "--deep", "--strict", bundle)
    for name in EXECUTABLES:
        run("lipo", bundle / "Contents" / "MacOS" / name, "-verify_arch", *ARCHITECTURES)


def archive_bundle(bundle, destination):
    run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", bundle, destination)


def package(stage, archive, args):
    sdk = output("xcrun", "--sdk", "macosx", "--show-sdk-path")
    clang = output("xcrun", "--find", "clang")
    products = {arch: build_slice(stage, arch, sdk, clang, args.sdk_release) for arch in ARCHITECTURES}

    bundle = stage / "Agent Commander.app"
    contents = bundle / "Contents"
    executables, resources = contents / "MacOS", contents / "Resources"
    executables.mkdir(parents=True)
    resources.mkdir()
    plist = ROOT / "packaging" / "Info.plist"
    if args.version:
        metadata = plistlib.loads(plist.read_bytes())
        metadata["CFBundleShortVersionString"] = args.version.split("-", 1)[0]
        metadata["CFBundleVersion"] = str(args.build_number)
        (contents / plist.name).write_bytes(plistlib.dumps(metadata))
    else:
        shutil.copy2(plist, contents)
    for name in RESOURCES:
        run("ditto", products["arm64"] / name, resources / name)

    sign = ("codesign", "--force", "--sign", args.sign)
    if args.notary_profile:
        sign += ("--options", "runtime", "--timestamp")
    for name in EXECUTABLES:
        binary = executables / name
        run("lipo", "-create", *(stage / arch / name for arch in ARCHITECTURES), "-output", binary)
        binary.chmod(0o755)
        if name != "AgentCommander":
            run(*sign, binary)
    run(*sign, bundle)
    verify_bundle(bundle)

    if args.notary_profile:
        submission = stage / "notarization-upload.zip"
        archive_bundle(bundle, submission)
        result = json.loads(output("xcrun", "notarytool", "submit", submission, "--wait",
                                   "--keychain-profile", args.notary_profile, "--output-format", "json"))
        if result.get("status") != "Accepted":
            raise SystemExit(f"Notarization {result.get('status')}: {result.get('id')}")
        run("xcrun", "stapler", "staple", bundle)

    archive_bundle(bundle, archive)
    restored = stage / "extracted"
    run("ditto", "-x", "-k", archive, restored)
    extracted = restored / bundle.name
    verify_bundle(extracted)
    if args.notary_profile:
        run("xcrun", "stapler", "validate", extracted)
        run("/usr/bin/syspolicy_check", "distribution", extracted)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sign", default="-", help="Developer ID Application signing identity")
    parser.add_argument("--sdk-release", help="directory containing the pinned Go SDK release")
    parser.add_argument("--notary-profile", help="notarytool Keychain profile for the distribution archive")
    parser.add_argument("--version", type=version, help="SemVer release tag for app bundle metadata")
    parser.add_argument("--build-number", type=int, default=1, help="positive app build number")
    parser.add_argument("--output-dir", type=Path, default=DIST, help="directory for the verified app archive")
    args = parser.parse_args()
    if args.build_number < 1:
        parser.error("the app build number must be positive")
    if args.notary_profile:
        if not args.sign.startswith("Developer ID Application: "):
            parser.error("notarization requires a Developer ID Application identity")
        identities = output("security", "find-identity", "-v", "-p", "codesigning")
        if f'"{args.sign}"' not in identities:
            parser.error("the Developer ID Application identity is unavailable in the current Keychain search list")
    elif args.sign != "-":
        parser.error("Developer ID signing requires a notarytool profile")

    suffix = "-notarized" if args.notary_profile else ""
    name = f"Agent-Commander-Multiplayer-Pilot-macOS-universal{suffix}.zip"
    destination = args.output_dir.resolve()
    destination.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".pilot-macos-", dir=destination) as folder:
        stage = Path(folder)
        archive = stage / name
        package(stage, archive, args)
        digest = hashlib.sha256()
        with archive.open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
        archive.replace(destination / name)
    print(f"{digest.hexdigest()}  {destination / name}")


if __name__ == "__main__":
    main()
