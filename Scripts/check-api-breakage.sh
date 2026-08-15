#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "${script_dir}/.." && pwd)"
cd "${repository_root}"

baseline="${1:-}"
if [[ -z "${baseline}" ]]; then
    baseline="$(
        git tag --merged HEAD --list 'v[0-9]*' --sort=-version:refname \
            | head -n 1
    )"
fi

if [[ -z "${baseline}" ]]; then
    echo "API compatibility: no version tag exists yet; baseline will start at v0.9.0"
    exit 0
fi

echo "API compatibility baseline: ${baseline}"
swift package diagnose-api-breaking-changes \
    "${baseline}" \
    --products Swiftix SwiftixBridge SwiftixPackages SwiftixImage SwiftixGo
