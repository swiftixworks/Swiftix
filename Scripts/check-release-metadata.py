#!/usr/bin/env python3

"""Validate the release identity shared by source, tags, and changelog."""

from __future__ import annotations

import argparse
import pathlib
import re
import subprocess
import sys


ROOT = pathlib.Path(__file__).resolve().parent.parent
SEMVER = re.compile(
    r"^(0|[1-9][0-9]*)\."
    r"(0|[1-9][0-9]*)\."
    r"(0|[1-9][0-9]*)"
    r"(?:-((?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)"
    r"(?:\.(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*))?"
    r"(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$",
    re.ASCII,
)


def fail(message: str) -> int:
    print(f"release metadata: {message}", file=sys.stderr)
    return 1


def source_metadata() -> tuple[str | None, int | None]:
    source = (ROOT / "Sources/Swiftix/Swiftix.swift").read_text()
    version = re.search(r'public static let version = "([^"]+)"', source)
    proc_schema = re.search(
        r"public static let teachingProcfsSchemaVersion = ([0-9]+)", source
    )
    return (
        version.group(1) if version else None,
        int(proc_schema.group(1)) if proc_schema else None,
    )


def exact_head_tags_when_clean() -> list[str]:
    dirty = subprocess.run(
        ["git", "diff", "--quiet", "HEAD", "--"], cwd=ROOT, check=False
    ).returncode != 0
    if dirty:
        return []
    result = subprocess.run(
        ["git", "tag", "--points-at", "HEAD", "--list", "v[0-9]*"],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    return [line for line in result.stdout.splitlines() if line]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag", help="release tag being built, for example v0.11.0")
    args = parser.parse_args()

    version, proc_schema = source_metadata()
    if version is None:
        return fail("could not read Swiftix.version")
    if SEMVER.fullmatch(version) is None:
        return fail(f"invalid Swiftix.version: {version}")

    changelog = (ROOT / "CHANGELOG.md").read_text()
    if "## Unreleased" not in changelog:
        return fail("CHANGELOG.md has no Unreleased section")

    compatibility = (ROOT / "docs/compatibility.md").read_text()
    if f"| Swiftix package | {version} |" not in compatibility:
        return fail("docs/compatibility.md does not match Swiftix.version")
    if proc_schema is None:
        return fail("could not read Swiftix.teachingProcfsSchemaVersion")
    if f"| Teaching procfs schema | {proc_schema} |" not in compatibility:
        return fail("docs/compatibility.md does not match teaching procfs schema")

    tags = [args.tag] if args.tag else exact_head_tags_when_clean()
    for tag in tags:
        if tag != f"v{version}":
            return fail(f"tag {tag} does not match Swiftix.version {version}")
        if f"## {version} " not in changelog:
            return fail(f"CHANGELOG.md has no release section for {version}")

    print(f"release metadata: Swiftix {version} is consistent")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
