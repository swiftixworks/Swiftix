#!/usr/bin/env bash

# Install, execute, and uninstall the host-native package on an ephemeral CI
# runner. Refuse to overwrite an existing installation so this remains safe
# when invoked manually.

set -euo pipefail

if (($# != 2)); then
    echo "usage: Packaging/smoke-test-toolchain.sh ARTIFACT_DIR VERSION" >&2
    exit 2
fi

artifact_dir="$1"
version="$2"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "${script_dir}/.." && pwd)"
"${repository_root}/Scripts/validate-semver.py" "${version}"

require_absent() {
    local path="$1"
    if [[ -e "${path}" ]]; then
        echo "refusing to overwrite existing path: ${path}" >&2
        exit 1
    fi
}

verify_commands() {
    local bin_dir="$1"
    for executable in swiftix-go; do
        local reported
        reported="$("${bin_dir}/${executable}" --version)"
        if [[ "${reported}" != "swiftix-toolchain ${version}" ]]; then
            echo "${executable} reports '${reported}', expected swiftix-toolchain ${version}" >&2
            exit 1
        fi
    done

    local smoke_root
    smoke_root="$(mktemp -d "${TMPDIR:-/tmp}/swiftix-toolchain-smoke.XXXXXX")"
    printf 'module smoke\n\ngo 1.24\n' >"${smoke_root}/go.mod"
    printf 'package main\nimport "fmt"\nfunc main() { fmt.Println("toolchain smoke") }\n' \
        >"${smoke_root}/main.go"
    (
        cd "${smoke_root}"
        "${bin_dir}/swiftix-go" build -o hello .
        test "$("${bin_dir}/swiftix-go" exec --root "${smoke_root}" hello)" = "toolchain smoke"
    )
    rm -rf "${smoke_root}"
}

case "$(uname -s)" in
    Darwin)
        package_path="${artifact_dir}/swiftix-toolchain-${version}-macos-$(uname -m).pkg"
        if [[ "$(uname -m)" == "x86_64" ]]; then
            package_path="${artifact_dir}/swiftix-toolchain-${version}-macos-amd64.pkg"
        fi
        test -f "${package_path}"
        require_absent /usr/local/bin/swiftix-go
        require_absent /usr/local/share/doc/swiftix-toolchain/LICENSE

        cleanup_macos() {
            sudo rm -f \
                /usr/local/bin/swiftix-go \
                /usr/local/share/doc/swiftix-toolchain/LICENSE
            sudo rmdir /usr/local/share/doc/swiftix-toolchain 2>/dev/null || true
            sudo pkgutil --forget org.swiftix.toolchain >/dev/null 2>&1 || true
        }
        trap cleanup_macos EXIT
        sudo installer -pkg "${package_path}" -target /
        verify_commands /usr/local/bin
        test -f /usr/local/share/doc/swiftix-toolchain/LICENSE
        cleanup_macos
        trap - EXIT
        require_absent /usr/local/bin/swiftix-go
        ;;
    Linux)
        architecture="$(dpkg --print-architecture)"
        package_path="${artifact_dir}/swiftix-toolchain_${version}_${architecture}.deb"
        test -f "${package_path}"
        require_absent /usr/bin/swiftix-go
        require_absent /usr/share/doc/swiftix-toolchain/copyright
        if dpkg-query -W -f='${Status}' swiftix-toolchain 2>/dev/null \
            | grep -q 'install ok installed'; then
            echo "refusing to replace an existing swiftix-toolchain package" >&2
            exit 1
        fi

        cleanup_linux() {
            if dpkg-query -W -f='${Status}' swiftix-toolchain 2>/dev/null \
                | grep -q 'install ok installed'; then
                sudo dpkg --remove swiftix-toolchain
            fi
        }
        trap cleanup_linux EXIT
        sudo dpkg --install "${package_path}"
        verify_commands /usr/bin
        test -f /usr/share/doc/swiftix-toolchain/copyright
        sudo dpkg --remove swiftix-toolchain
        trap - EXIT
        require_absent /usr/bin/swiftix-go
        ;;
    *)
        echo "unsupported package smoke host: $(uname -s)" >&2
        exit 1
        ;;
esac

echo "Swiftix toolchain package install/uninstall smoke passed"
