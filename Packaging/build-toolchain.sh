#!/usr/bin/env bash

# Build the host executable as a version-locked Swiftix toolchain release.
# macOS runners may set SWIFTIX_APPLICATION_SIGN_IDENTITY and
# SWIFTIX_INSTALLER_SIGN_IDENTITY to sign the binaries and flat installer.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "${script_dir}/.." && pwd)"
output_dir="${repository_root}/.build/toolchain-artifacts"
requested_version=""
requested_formats="all"
source_commit=""
skip_build=false

usage() {
    cat <<'EOF'
usage: Packaging/build-toolchain.sh [options]

Options:
  --version VERSION       Release version; must equal Swiftix.version.
  --output-dir DIRECTORY  Artifact destination (default: .build/toolchain-artifacts).
  --formats LIST          Comma-separated pkg,deb,tar.gz or "all".
  --source-commit SHA     Source commit recorded beside the checksums.
  --skip-build            Package existing release binaries.
  -h, --help              Show this help.

Linux builds link the Swift standard library statically by default. Set
SWIFTIX_STATIC_SWIFT_STDLIB=false to disable that behavior.
EOF
}

while (($# > 0)); do
    case "$1" in
        --version)
            requested_version="${2:?missing value for --version}"
            shift 2
            ;;
        --output-dir)
            output_dir="${2:?missing value for --output-dir}"
            shift 2
            ;;
        --formats)
            requested_formats="${2:?missing value for --formats}"
            shift 2
            ;;
        --source-commit)
            source_commit="${2:?missing value for --source-commit}"
            shift 2
            ;;
        --skip-build)
            skip_build=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

swiftix_version="$(sed -n 's/.*public static let version = "\([^"]*\)".*/\1/p' "${repository_root}/Sources/Swiftix/Swiftix.swift" | head -n 1)"
if [[ -z "${swiftix_version}" ]]; then
    echo "could not read Swiftix.version" >&2
    exit 1
fi
version="${requested_version:-${swiftix_version}}"
if [[ "${version}" != "${swiftix_version}" ]]; then
    echo "release version ${version} does not match Swiftix.version ${swiftix_version}" >&2
    exit 1
fi
"${repository_root}/Scripts/validate-semver.py" "${version}"
if [[ -n "${source_commit}" && ! "${source_commit}" =~ ^[0-9a-f]{7,64}$ ]]; then
    echo "source commit must be 7-64 lowercase hexadecimal characters" >&2
    exit 2
fi

host_os="$(uname -s)"
host_machine="$(uname -m)"
case "${host_os}" in
    Darwin)
        platform="macos"
        default_formats="pkg,tar.gz"
        ;;
    Linux)
        platform="linux"
        default_formats="deb,tar.gz"
        ;;
    *)
        echo "unsupported packaging host: ${host_os}" >&2
        exit 1
        ;;
esac
case "${host_machine}" in
    arm64|aarch64)
        architecture="arm64"
        debian_architecture="arm64"
        ;;
    x86_64|amd64)
        architecture="amd64"
        debian_architecture="amd64"
        ;;
    *)
        echo "unsupported packaging architecture: ${host_machine}" >&2
        exit 1
        ;;
esac

formats="${requested_formats}"
if [[ "${formats}" == "all" ]]; then
    formats="${default_formats}"
fi
IFS=',' read -r -a format_list <<<"${formats}"
if ((${#format_list[@]} == 0)); then
    echo "no packaging format requested" >&2
    exit 2
fi
for format in "${format_list[@]}"; do
    case "${format}" in
        pkg|deb|tar.gz) ;;
        *)
            echo "unsupported packaging format: ${format}" >&2
            exit 2
            ;;
    esac
done
if [[ "${platform}" != "macos" && ",${formats}," == *,pkg,* ]]; then
    echo "pkg output requires macOS" >&2
    exit 2
fi
if [[ "${platform}" != "linux" && ",${formats}," == *,deb,* ]]; then
    echo "deb output requires Linux" >&2
    exit 2
fi

build_flags=(-c release -Xswiftc -warnings-as-errors)
if [[ "${platform}" == "linux" && "${SWIFTIX_STATIC_SWIFT_STDLIB:-true}" != "false" ]]; then
    build_flags+=(--static-swift-stdlib)
fi

if [[ "${skip_build}" != "true" ]]; then
    swift build --package-path "${repository_root}" "${build_flags[@]}" --product swiftix-go
fi
binary_dir="$(swift build --package-path "${repository_root}" "${build_flags[@]}" --show-bin-path)"
for executable in swiftix-go; do
    if [[ ! -x "${binary_dir}/${executable}" ]]; then
        echo "missing release executable: ${binary_dir}/${executable}" >&2
        exit 1
    fi
    reported_version="$("${binary_dir}/${executable}" --version)"
    if [[ "${reported_version}" != "swiftix-toolchain ${version}" ]]; then
        echo "${executable} reports '${reported_version}', expected swiftix-toolchain ${version}" >&2
        exit 1
    fi
done

mkdir -p "${output_dir}"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/swiftix-toolchain.XXXXXX")"
cleanup() {
    rm -rf "${temporary_root}"
}
trap cleanup EXIT

payload_root="${temporary_root}/swiftix-toolchain-${version}-${platform}-${architecture}"
mkdir -p "${payload_root}/bin" "${payload_root}/share/doc/swiftix-toolchain"
install -m 0755 "${binary_dir}/swiftix-go" "${payload_root}/bin/swiftix-go"
install -m 0644 "${repository_root}/LICENSE" "${payload_root}/share/doc/swiftix-toolchain/LICENSE"

if [[ "${platform}" == "macos" && -n "${SWIFTIX_APPLICATION_SIGN_IDENTITY:-}" ]]; then
    printf 'Signing swiftix-go with Developer ID Application\n'
    codesign --force --options runtime --timestamp --sign "${SWIFTIX_APPLICATION_SIGN_IDENTITY}" "${payload_root}/bin/swiftix-go"
fi

normalize_mtime() {
    local root="$1"
    if touch -h -t 200001010000 "${root}" >/dev/null 2>&1; then
        find "${root}" -exec touch -h -t 200001010000 {} +
    else
        find "${root}" -exec touch -t 200001010000 {} +
    fi
}
normalize_mtime "${payload_root}"

artifacts=()
if [[ ",${formats}," == *,tar.gz,* ]]; then
    archive_path="${output_dir}/swiftix-toolchain-${version}-${platform}-${architecture}.tar.gz"
    archive_name="$(basename "${payload_root}")"
    COPYFILE_DISABLE=1 tar -cf "${temporary_root}/toolchain.tar" -C "${temporary_root}" "${archive_name}"
    gzip -n -9 -c "${temporary_root}/toolchain.tar" >"${archive_path}"
    artifacts+=("${archive_path}")
fi

if [[ ",${formats}," == *,pkg,* ]]; then
    package_root="${temporary_root}/pkg-root"
    mkdir -p "${package_root}/usr/local/bin" "${package_root}/usr/local/share/doc/swiftix-toolchain"
    install -m 0755 "${payload_root}/bin/swiftix-go" "${package_root}/usr/local/bin/swiftix-go"
    install -m 0644 "${repository_root}/LICENSE" "${package_root}/usr/local/share/doc/swiftix-toolchain/LICENSE"
    normalize_mtime "${package_root}"
    package_path="${output_dir}/swiftix-toolchain-${version}-macos-${architecture}.pkg"
    pkgbuild_arguments=(
        --root "${package_root}"
        --identifier org.swiftix.toolchain
        --version "${version}"
        --install-location /
        --ownership recommended
    )
    if [[ -n "${SWIFTIX_INSTALLER_SIGN_IDENTITY:-}" ]]; then
        pkgbuild_arguments+=(--sign "${SWIFTIX_INSTALLER_SIGN_IDENTITY}")
    fi
    printf 'Building macOS installer package\n'
    pkgbuild "${pkgbuild_arguments[@]}" "${package_path}"
    if [[ -n "${SWIFTIX_NOTARY_KEY_FILE:-}" ]]; then
        if [[ -z "${SWIFTIX_NOTARY_KEY_ID:-}" || -z "${SWIFTIX_NOTARY_ISSUER_ID:-}" ]]; then
            echo "SWIFTIX_NOTARY_KEY_ID and SWIFTIX_NOTARY_ISSUER_ID are required with SWIFTIX_NOTARY_KEY_FILE" >&2
            exit 1
        fi
        printf 'Submitting macOS installer package for notarization\n'
        xcrun notarytool submit "${package_path}" \
            --key "${SWIFTIX_NOTARY_KEY_FILE}" \
            --key-id "${SWIFTIX_NOTARY_KEY_ID}" \
            --issuer "${SWIFTIX_NOTARY_ISSUER_ID}" \
            --wait
        xcrun stapler staple "${package_path}"
        xcrun stapler validate "${package_path}"
    fi
    artifacts+=("${package_path}")
fi

if [[ ",${formats}," == *,deb,* ]]; then
    debian_root="${temporary_root}/debian-root"
    mkdir -p "${debian_root}/DEBIAN" "${debian_root}/usr/bin" "${debian_root}/usr/share/doc/swiftix-toolchain"
    install -m 0755 "${payload_root}/bin/swiftix-go" "${debian_root}/usr/bin/swiftix-go"
    install -m 0644 "${repository_root}/LICENSE" "${debian_root}/usr/share/doc/swiftix-toolchain/copyright"
    installed_kib="$(du -sk "${debian_root}/usr" | awk '{print $1}')"
    libc_version="$(dpkg-query -W -f='${Version}' libc6)"
    libgcc_version="$(dpkg-query -W -f='${Version}' libgcc-s1)"
    libstdcxx_version="$(dpkg-query -W -f='${Version}' libstdc++6)"
    cat >"${debian_root}/DEBIAN/control" <<EOF
Package: swiftix-toolchain
Version: ${version}
Section: devel
Priority: optional
Architecture: ${debian_architecture}
Maintainer: Swiftix Project <swiftix@holdon.work>
Installed-Size: ${installed_kib}
Depends: libc6 (>= ${libc_version}), libgcc-s1 (>= ${libgcc_version}), libstdc++6 (>= ${libstdcxx_version})
Homepage: https://github.com/castorworks/Swiftix
Description: Swiftix Go-compatible host toolchain
 Contains swiftix-go for building, testing, and executing Swiftix/svm64 programs.
EOF
    normalize_mtime "${debian_root}"
    package_path="${output_dir}/swiftix-toolchain_${version}_${debian_architecture}.deb"
    SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-946684800}" dpkg-deb --root-owner-group --build "${debian_root}" "${package_path}"
    artifacts+=("${package_path}")
fi

checksum_file="${output_dir}/SHA256SUMS-${version}-${platform}-${architecture}"
: >"${checksum_file}"
for artifact in "${artifacts[@]}"; do
    if command -v sha256sum >/dev/null 2>&1; then
        (cd "${output_dir}" && sha256sum "$(basename "${artifact}")") >>"${checksum_file}"
    else
        digest="$(shasum -a 256 "${artifact}" | awk '{print $1}')"
        printf '%s  %s\n' "${digest}" "$(basename "${artifact}")" >>"${checksum_file}"
    fi
done
printf '# source-commit: %s\n' "${source_commit:-unknown}" >>"${checksum_file}"

printf 'Swiftix toolchain %s (%s/%s)\n' "${version}" "${platform}" "${architecture}"
for artifact in "${artifacts[@]}"; do
    printf '  %s\n' "${artifact}"
done
printf '  %s\n' "${checksum_file}"
