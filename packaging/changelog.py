#!/usr/bin/env python3
"""Validate the changelog, cut a version, or extract its GitHub release notes."""

import argparse
from datetime import date, datetime, timezone
from pathlib import Path
import re


CHANGELOG = Path(__file__).resolve().parents[1] / "CHANGELOG.md"
HEADING = re.compile(r"^## \[([^\]\n]+)\](?: - (\d{4}-\d{2}-\d{2}))?[ \t]*$", re.MULTILINE)
VERSION = re.compile(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?")


def version(value):
    value = value.removeprefix("v")
    match = VERSION.fullmatch(value)
    if not match or any(
        part.isdigit() and len(part) > 1 and part.startswith("0")
        for part in (match[4] or "").split(".")
    ):
        raise ValueError(f"Invalid release version: {value}")
    return value


def parse(text):
    headings = list(HEADING.finditer(text))
    if not headings or headings[0].groups() != ("Unreleased", None):
        raise ValueError("Start version sections with an undated ## [Unreleased] heading")
    entries = {}
    for index, heading in enumerate(headings):
        label, published = heading.groups()
        end = headings[index + 1].start() if index + 1 < len(headings) else len(text)
        body = text[heading.end():end].strip()
        if label in entries:
            raise ValueError(f"Duplicate changelog section: {label}")
        if label != "Unreleased":
            if label != version(label) or not published or not body:
                raise ValueError(f"Released section must contain a version, ISO date, and notes: {label}")
            date.fromisoformat(published)
        entries[label] = body
    return headings[0], entries


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("check")
    for command in ("cut", "notes"):
        commands.add_parser(command).add_argument("version")
    args = parser.parse_args()

    text = CHANGELOG.read_text(encoding="utf-8")
    try:
        unreleased, entries = parse(text)
        if args.command == "check":
            return
        label = version(args.version)
        if args.command == "notes":
            if label not in entries:
                raise ValueError(f"No changelog section for v{label}; run changelog.py cut first")
            print(entries[label])
            return
        if label in entries:
            raise ValueError(f"v{label} already appears in the changelog")
        if not entries["Unreleased"]:
            raise ValueError("Unreleased has no changes to cut")
        today = datetime.now(timezone.utc).date().isoformat()
        updated = text[:unreleased.end()] + f"\n\n## [{label}] - {today}\n" + text[unreleased.end():]
        parse(updated)
        CHANGELOG.write_text(updated, encoding="utf-8")
    except ValueError as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
