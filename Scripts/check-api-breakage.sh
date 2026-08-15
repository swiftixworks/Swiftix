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

current_version="$(
    sed -n 's/.*public static let version = "\([^"]*\)".*/\1/p' \
        Sources/Swiftix/Swiftix.swift
)"
baseline_version="$(
    git show "${baseline}:Sources/Swiftix/Swiftix.swift" \
        | sed -n 's/.*public static let version = "\([^"]*\)".*/\1/p'
)"

if [[ -z "${current_version}" || -z "${baseline_version}" ]]; then
    echo "API compatibility: could not resolve current/baseline package versions" >&2
    exit 1
fi

compatibility_series() {
    local version="${1%%[-+]*}"
    local major minor patch
    IFS=. read -r major minor patch <<<"${version}"
    if [[ -z "${major}" || -z "${minor}" || -z "${patch}" ]]; then
        return 1
    fi
    if [[ "${major}" == "0" ]]; then
        printf '0.%s\n' "${minor}"
    else
        printf '%s\n' "${major}"
    fi
}

current_series="$(compatibility_series "${current_version}")"
baseline_series="$(compatibility_series "${baseline_version}")"
effective_baseline="${baseline}"

if [[ "${current_series}" != "${baseline_series}" ]]; then
    series_baseline=""
    while IFS= read -r commit; do
        commit_version="$(
            git show "${commit}:Sources/Swiftix/Swiftix.swift" \
                | sed -n 's/.*public static let version = "\([^"]*\)".*/\1/p'
        )"
        if [[ -z "${commit_version}" ]]; then
            continue
        fi
        commit_series="$(compatibility_series "${commit_version}")"
        if [[ "${commit_series}" == "${current_series}" ]]; then
            series_baseline="${commit}"
        elif [[ -n "${series_baseline}" ]]; then
            break
        fi
    done < <(git log --format='%H' -- Sources/Swiftix/Swiftix.swift)

    printf '%s\n' \
        "API compatibility: ${baseline_version} -> ${current_version} changes compatibility series (${baseline_series} -> ${current_series}); the versioned break is accepted"
    if [[ -z "${series_baseline}" ]]; then
        echo "API compatibility: the new series is not committed yet; no same-series baseline exists"
        exit 0
    fi
    effective_baseline="${series_baseline}"
    echo "API compatibility baseline for ${current_series}.x: ${effective_baseline}"
fi

swift package diagnose-api-breaking-changes \
    "${effective_baseline}" \
    --products Swiftix SwiftixBridge SwiftixPackages SwiftixImage SwiftixGo
