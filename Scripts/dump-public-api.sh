#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "${script_dir}/.." && pwd)"
cd "${repository_root}"

swift package dump-symbol-graph \
    --minimum-access-level public \
    --pretty-print \
    --skip-synthesized-members
