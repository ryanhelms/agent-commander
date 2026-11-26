#!/usr/bin/env python3
"""Copy a Homebrew PostgreSQL keg into a self-contained folder for the app bundle.

Usage: bundle-postgres.py DEST [--formula postgresql@17]

DEST receives bin/, lib/, share/ from the keg. Every non-system dylib the
binaries and server modules load is copied into DEST/lib/deps and rewritten
to an @loader_path reference, then everything is ad hoc signed so it runs
from inside Agent Commander.app.
"""
import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

KEEP_BINS = ["postgres", "initdb", "pg_ctl", "pg_isready", "psql", "pg_dump", "pg_restore"]


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True, errors="replace").stdout


def deps(path):
    out = run("otool", "-L", str(path)).splitlines()[1:]
    return [line.strip().split(" (")[0] for line in out]


def is_external(dep):
    return dep.startswith("/opt/homebrew/") or dep.startswith("/usr/local/")


def macho(path):
    try:
        return run("file", "-b", str(path)).startswith("Mach-O")
    except subprocess.CalledProcessError:
        return False


def main():
    p = argparse.ArgumentParser()
    p.add_argument("dest", type=Path)
    p.add_argument("--formula", default="postgresql@17")
    a = p.parse_args()
    keg = Path(run("brew", "--prefix", a.formula).strip()).resolve()
    if not (keg / "bin" / "postgres").exists():
        sys.exit(f"{a.formula} is not installed; run: brew install {a.formula}")
    dest = a.dest.resolve()
    if dest.exists():
        shutil.rmtree(dest)
    (dest / "bin").mkdir(parents=True)
    for name in KEEP_BINS:
        shutil.copy2(keg / "bin" / name, dest / "bin" / name)
    shutil.copytree(keg / "lib", dest / "lib", symlinks=False,
                    ignore=shutil.ignore_patterns("*.a", "pkgconfig", "pgxs"))
    shutil.copytree(keg / "share", dest / "share", symlinks=False,
                    ignore=shutil.ignore_patterns("man", "doc"))
    depdir = dest / "lib" / "deps"
    depdir.mkdir(exist_ok=True)

    files = [f for f in dest.rglob("*") if f.is_file() and not f.is_symlink() and macho(f)]
    queue = [(f, None) for f in files]
    copied = {}
    while queue:
        f, origin = queue.pop()
        os.chmod(f, 0o755)
        for d in deps(f):
            if is_external(d):
                src = Path(d)
            elif origin and (d.startswith("@loader_path/") or d.startswith("@rpath/")):
                src = origin / d.split("/", 1)[1]
                if not src.exists():
                    continue
            else:
                continue
            name = src.name
            target = depdir / name
            if name not in copied:
                real = src.resolve()
                shutil.copy2(real, target)
                os.chmod(target, 0o755)
                copied[name] = target
                queue.append((target, real.parent))
            rel = os.path.relpath(depdir, f.parent)
            ref = "@loader_path/" + (name if rel == "." else f"{rel}/{name}")
            if d != ref:
                run("install_name_tool", "-change", d, ref, str(f))
        if f.suffix == ".dylib":
            run("install_name_tool", "-id", "@loader_path/" + f.name, str(f))
    for f in list(files) + list(copied.values()):
        run("codesign", "--force", "--sign", "-", str(f))
    leftovers = [(str(f), d) for f in dest.rglob("*") if f.is_file() and macho(f) for d in deps(f) if is_external(d)]
    if leftovers:
        sys.exit(f"unrewritten Homebrew references: {leftovers[:5]}")
    print(f"bundled {a.formula} from {keg} into {dest} with {len(copied)} libraries")


if __name__ == "__main__":
    main()
