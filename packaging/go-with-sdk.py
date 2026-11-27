#!/usr/bin/env python3
"""Run a Commander Go release build or test against its pinned SDK archive."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SDK = "agent-acp.local/sdks/go"
TRANSPORT = "agent-acp.local/transport"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release", type=Path, help="SDK directory override (default: the version in go.mod under dist/sdk)")
    parser.add_argument("action", choices=("build", "test"))
    parser.add_argument("args", nargs=argparse.REMAINDER)
    args = sys.argv[1:]
    # Earlier releases accepted the SDK directory before the action.
    if len(args) > 1 and args[1] in ("build", "test") and not args[0].startswith("-"):
        args = ["--release", *args]
    options = parser.parse_args(args)
    if any(arg.lstrip("-").split("=")[0] in ("mod", "modfile", "overlay") and arg.startswith("-")
           for arg in options.args):
        parser.error("release builds use the pinned module file without an overlay")
    env = os.environ | {"GOWORK": "off", "GOFLAGS": ""}
    configured = json.loads(subprocess.check_output(
        ["go", "env", "-json", "GOPROXY", "GOMODCACHE", "GONOSUMDB"], cwd=ROOT, env=env
    ))
    module = json.loads(subprocess.check_output(["go", "mod", "edit", "-json"], cwd=ROOT, env=env))
    required = {item["Path"]: item["Version"] for item in module.get("Require") or []}
    sdk_version = required.get(SDK)
    if not sdk_version:
        parser.error(f"go.mod must require a release version of {SDK}")
    locked = {tuple(line.split()[:2]) for line in (ROOT / "go.sum").read_text().splitlines()}
    release = (options.release or ROOT / "dist" / "sdk" / ("agent-acp-" + sdk_version.removeprefix("v"))).resolve()
    with tempfile.TemporaryDirectory(prefix="commander-release-") as folder:
        workspace = Path(folder)
        modfile = workspace / "release.mod"
        shutil.copyfile(ROOT / "go.mod", modfile)
        shutil.copyfile(ROOT / "go.sum", workspace / "release.sum")
        subprocess.run(["go", "mod", "edit", "-dropreplace=" + SDK, "-dropreplace=" + TRANSPORT, modfile],
                       cwd=ROOT, env=env, check=True)
        env.update({
            "GOMODCACHE": str(workspace / "modules"),
            "GONOPROXY": "none",
            "GONOSUMDB": ",".join(filter(None, [SDK, TRANSPORT, configured["GONOSUMDB"]])),
        })

        def download(name, version, source):
            if (name, version) not in locked or (name, version + "/go.mod") not in locked:
                parser.error(f"go.sum is missing the release checksums for {name}@{version}")
            proxy = source / "go"
            for suffix in (".mod", ".info", ".zip"):
                if not (proxy / name / "@v" / (version + suffix)).is_file():
                    parser.error(f"{source} has no Go proxy artifact for {name}@{version}{suffix}")
            # One staged proxy per pin. The caller's checkout, remote proxy and
            # previous module cache cannot substitute for either supplied archive.
            env["GOPROXY"] = proxy.as_uri()
            result = subprocess.run(["go", "mod", "download", "-json", "-modfile=" + str(modfile), name + "@" + version],
                                    cwd=ROOT, env=env, stdout=subprocess.PIPE, text=True)
            if result.returncode:
                # Go returns a JSON error on stdout for -json downloads.
                if result.stdout:
                    print(result.stdout, file=sys.stderr, end="")
                result.check_returncode()
            return Path(json.loads(result.stdout)["GoMod"])

        sdk_mod = download(SDK, sdk_version, release)
        sdk = json.loads(subprocess.check_output(["go", "mod", "edit", "-json", sdk_mod], cwd=ROOT, env=env))
        dependency = next((r["Version"] for r in sdk.get("Require", []) if r["Path"] == TRANSPORT), None)
        if dependency is not None:
            version = required.get(TRANSPORT, dependency)
            adjacent = release.parent / ("agent-acp-transport-" + version.removeprefix("v"))
            source = Path(env.get("AGENT_ACP_TRANSPORT_RELEASE", adjacent)).resolve()
            download(TRANSPORT, version, source)
        local_public_proxy = (Path(configured["GOMODCACHE"]) / "cache/download").resolve().as_uri()
        env["GOPROXY"] = ",".join(filter(None, [local_public_proxy, configured["GOPROXY"]]))
        if options.action == "test":
            # Integration fixtures build agentctl in child Go commands. Inherit
            # these same pins even when a fixture runs outside the root package.
            env["GOFLAGS"] = f'-mod=readonly "-modfile={modfile}"'
        subprocess.run(["go", options.action, "-mod=readonly", "-modfile=" + str(modfile), *options.args],
                       cwd=ROOT, env=env, check=True)


if __name__ == "__main__":
    main()
