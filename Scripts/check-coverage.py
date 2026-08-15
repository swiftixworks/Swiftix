#!/usr/bin/env python3

import json
import pathlib
import sys


def main() -> int:
    if len(sys.argv) not in (2, 3):
        print("usage: check-coverage.py CODECOV_JSON [MINIMUM_PERCENT]", file=sys.stderr)
        return 2

    path = pathlib.Path(sys.argv[1])
    minimum = float(sys.argv[2]) if len(sys.argv) == 3 else 80.0
    with path.open("r", encoding="utf-8") as handle:
        report = json.load(handle)

    files = report["data"][0]["files"]
    source_summaries = [
        item["summary"]["lines"]
        for item in files
        if "/Sources/" in item["filename"].replace("\\", "/")
    ]
    if not source_summaries:
        print("coverage report contains no Sources files", file=sys.stderr)
        return 1

    covered = sum(item["covered"] for item in source_summaries)
    count = sum(item["count"] for item in source_summaries)
    percent = 100.0 * covered / count if count else 100.0
    print(f"source line coverage: {percent:.2f}% ({covered}/{count}); minimum {minimum:.2f}%")
    return 0 if percent >= minimum else 1


if __name__ == "__main__":
    raise SystemExit(main())
