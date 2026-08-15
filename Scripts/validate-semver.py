#!/usr/bin/env python3

import re
import sys


SEMVER = re.compile(
    r"^(0|[1-9][0-9]*)\."
    r"(0|[1-9][0-9]*)\."
    r"(0|[1-9][0-9]*)"
    r"(?:-((?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)"
    r"(?:\.(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*))?"
    r"(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$",
    re.ASCII,
)


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: validate-semver.py VERSION", file=sys.stderr)
        return 2
    version = sys.argv[1]
    if SEMVER.fullmatch(version) is None:
        print(f"invalid semantic version: {version}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
