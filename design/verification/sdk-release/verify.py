#!/usr/bin/env python3
"""Verify conformance against the installed Go, npm and Python SDK artifacts."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import zipfile

CONTRACTS = Path(__file__).resolve().parent / "consumer"


def run(args, directory, env=None):
    subprocess.run(args, cwd=directory, env=env, check=True)


def check_manifest(release):
    manifest = json.loads((release / "manifest.json").read_text())
    for name, digest in manifest["sha256"].items():
        filename = (release / name).resolve()
        if not filename.is_relative_to(release) or hashlib.sha256(filename.read_bytes()).hexdigest() != digest:
            raise ValueError(f"Release artifact does not match its manifest: {name}")
    return manifest


def verify_standalone_go(consumer, releases, fixture):
    sdk_release, sdk_manifest = releases[0]
    module = sdk_manifest["goModule"]
    version = "v" + sdk_manifest["version"]
    env = os.environ | {"GOWORK": "off", "GOFLAGS": ""}
    settings = json.loads(subprocess.check_output(
        ["go", "env", "-json", "GOMODCACHE", "GOPROXY", "GONOSUMDB"], cwd=consumer, env=env))
    env.update({
        "GOMODCACHE": str(consumer / "go-modules"),
        "GONOPROXY": "none",
        "GONOSUMDB": ",".join([manifest["goModule"] for _, manifest in releases] + [settings["GONOSUMDB"]]),
    })
    run(["go", "mod", "init", "consumer.example/verification"], consumer, env)
    # The packaged SDK pins its transport and public dependencies even when the
    # offline consumer cannot reach a checksum service.
    sdk_zip = sdk_release / "go" / module / "@v" / (version + ".zip")
    with zipfile.ZipFile(sdk_zip) as archive:
        (consumer / "go.sum").write_bytes(archive.read(f"{module}@{version}/go.sum"))
    for directory, manifest in releases:
        pin = manifest["goModule"] + "@v" + manifest["version"]
        run(["go", "mod", "edit", "-require=" + pin], consumer, env)
        local = env | {"GOPROXY": (directory / "go").as_uri()}
        run(["go", "mod", "download", pin], consumer, local)

    cached_public = (Path(settings["GOMODCACHE"]) / "cache/download").resolve().as_uri()
    env["GOPROXY"] = ",".join(filter(None, [cached_public, settings["GOPROXY"]]))
    # Validate the Go fixture and execute both conformance implementations out
    # of the installed module. A renamed, skipped or missing test must fail.
    sdk = json.loads(subprocess.check_output(
        ["go", "list", "-m", "-json", module], cwd=consumer, env=env))
    installed = Path(sdk["Dir"]).resolve()
    if "Replace" in sdk or not installed.is_relative_to(consumer / "go-modules"):
        raise RuntimeError("Go did not resolve the SDK from the fresh module cache")
    if (installed / "testdata/session.json").read_bytes() != fixture.read_bytes():
        raise RuntimeError("The Go archive and language bindings have different contract fixtures")
    expected = {
        (module, "TestSessionContract"),
        (module + "/runtime", "TestExecutableAdapterPortableConformance"),
        (module + "/conformance", "TestEmbeddedAdapterConformance"),
    }
    result = subprocess.run(
        ["go", "test", "-json", "-mod=mod", "-count=1", module, module + "/runtime",
         module + "/nativehistory", module + "/conformance"], cwd=consumer, env=env,
        text=True, stdout=subprocess.PIPE)
    if result.returncode:
        print(result.stdout, file=sys.stderr, end="")
        result.check_returncode()
    for line in result.stdout.splitlines():
        event = json.loads(line)
        if event["Action"] == "pass":
            expected.discard((event.get("Package"), event.get("Test")))
    if expected:
        raise RuntimeError(f"Required installed Go tests did not pass: {sorted(expected)}")
    checker = consumer / "adapter-conformance"
    run(["go", "build", "-mod=readonly", "-o", checker, module + "/cmd/adapter-conformance"], consumer, env)
    print("Installed Go session contract, compiled adapter and executable ACP adapter passed. "
          "Built the distributed adapter-conformance command.", flush=True)


def verify_tamper_rejection(root, sdk_release, altered_release, module, version, work, transport_release=None):
    altered = work / ("altered-" + altered_release.name)
    shutil.copytree(altered_release / "go", altered / "go")
    target = altered / "go" / module / "@v" / f"v{version}.zip"
    replacement = target.with_suffix(".tmp")
    changed = False
    with zipfile.ZipFile(target) as original, zipfile.ZipFile(replacement, "w") as modified:
        for item in original.infolist():
            data = original.read(item)
            if not changed and item.filename.endswith(".go") and not item.filename.endswith("_test.go"):
                data += b"\n// changed after release\n"
                changed = True
            modified.writestr(item, data)
    if not changed:
        raise RuntimeError("Release archive had no Go implementation to check")
    replacement.replace(target)
    env = os.environ.copy()
    if transport_release is not None:
        env["AGENT_ACP_TRANSPORT_RELEASE"] = str(altered if altered_release == transport_release else transport_release)
    selected = altered if altered_release == sdk_release else sdk_release
    unwanted = work / "unexpected"
    result = subprocess.run(
        [sys.executable, root / "packaging/go-with-sdk.py", selected,
         "build", "-o", unwanted, "./cmd/agentctl"],
        cwd=root, env=env, capture_output=True, text=True,
    )
    if result.returncode == 0 or "checksum mismatch" not in result.stderr or unwanted.exists():
        raise RuntimeError(f"Commander did not reject the altered {module} release at checksum verification")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("release", type=Path)
    parser.add_argument("--sdk-checkout", type=Path, help="use alternate binding test sources from an SDK development checkout")
    parser.add_argument("--consumer-only", action="store_true", help="verify without a Commander checkout or its Go pins")
    args = parser.parse_args()
    release = args.release.resolve()
    checkout = args.sdk_checkout.resolve() if args.sdk_checkout else None
    manifest = check_manifest(release)
    version = manifest["version"]
    module = manifest["goModule"]
    with tempfile.TemporaryDirectory(prefix="commander-sdk-consumers-") as folder:
        consumer = Path(folder).resolve()
        sdk_mod = release / "go" / module / "@v" / ("v" + version + ".mod")
        metadata = json.loads(subprocess.check_output(["go", "mod", "edit", "-json", sdk_mod], cwd=consumer))
        transport = "agent-acp.local/transport"
        transport_version = next((r["Version"].removeprefix("v") for r in metadata.get("Require", [])
                                  if r["Path"] == transport), None)
        transport_release = None
        if transport_version is not None:
            adjacent = release.parent / ("agent-acp-transport-" + transport_version)
            transport_release = Path(os.environ.get("AGENT_ACP_TRANSPORT_RELEASE", adjacent)).resolve()
        releases = [(release, manifest)]
        if transport_release is not None:
            transport_manifest = check_manifest(transport_release)
            if transport_manifest["goModule"] != transport or transport_manifest["version"] != transport_version:
                raise ValueError("Transport manifest does not match the SDK dependency")
            releases.append((transport_release, transport_manifest))
        if args.consumer_only:
            verify_standalone_go(consumer, releases, release / "conformance/session.json")
        else:
            root = Path(__file__).resolve().parents[3]
            run([sys.executable, root / "packaging/go-with-sdk.py", release, "test", "-count=1",
                 module, module + "/runtime", module + "/nativehistory", module + "/conformance"], root)
            verify_tamper_rejection(root, release, release, module, version, consumer, transport_release)
            if transport_release is not None:
                verify_tamper_rejection(root, release, transport_release, transport, transport_version, consumer, transport_release)
        shutil.copytree(release / "conformance", consumer / "conformance")
        ts_test = consumer / "sdks/typescript/test"
        ts_test.mkdir(parents=True)
        ts_source = checkout / "sdks/typescript/test" if checkout else CONTRACTS
        shutil.copyfile(ts_source / "contract.test.mjs", ts_test / "contract.test.mjs")
        shutil.copyfile(CONTRACTS / "types.mts", consumer / "types.mts")
        # An explicit npm project prevents resolution through an ancestor's workspace.
        (consumer / "package.json").write_text('{"private":true,"type":"module"}\n')
        run(["npm", "install", "--ignore-scripts", "--no-audit", "--no-fund",
             "typescript@5.9.3", release / f"npm/agent-acp-{version}.tgz"], consumer)
        run(["node", consumer / "node_modules/typescript/bin/tsc", "--noEmit", "--strict",
             "--target", "ES2022", "--module", "NodeNext", "types.mts"], consumer)
        run(["node", "--test", ts_test / "contract.test.mjs"], consumer)

        py_test = consumer / "sdks/python/tests"
        py_test.mkdir(parents=True)
        py_source = checkout / "sdks/python/tests" if checkout else CONTRACTS
        shutil.copyfile(py_source / "test_contract.py", py_test / "test_contract.py")
        venv = consumer / "venv"
        env = {key: value for key, value in os.environ.items() if key not in ("PYTHONPATH", "PYTHONHOME")}
        run([sys.executable, "-m", "venv", venv], consumer, env)
        python = venv / "bin/python"
        run([python, "-m", "pip", "--disable-pip-version-check", "install",
             release / f"python/agent_acp-{version}-py3-none-any.whl"], consumer, env)
        run([python, "-m", "unittest", "discover", "-s", py_test], consumer, env)


if __name__ == "__main__":
    main()
