#!/usr/bin/env bash
# Publish a signed Android APK together with KOReader's in-app OTA assets.
#
# Usage:
#   tools/release-android.sh --apk koreader-android-arm64-v2026.16.apk \
#       --version v2026.16 --notes-file /tmp/opencode/release-notes-v2026.16.md
#
# The script creates the GitHub release when it does not exist, then uploads
# (with --clobber):
#   * the APK and its .sha256 file,
#   * koreader-android-arm64-latest-stable (built-in OTA manifest),
#   * latest.json (version/url/sha256 metadata).
#
# The manifest and latest.json must live in the *latest* release. GitHub's
# /releases/latest/download/ URL then resolves the manifest, and the manifest
# resolves the APK from the same release.
#
# IMPORTANT: `kodev release android-arm64` produces a debug-signed APK.  It
# MUST be re-signed with the fork's release key before this script runs:
#   tools/sign-android-release.sh --apk koreader-android-arm64-vYYYY.MM.apk
# Otherwise Android rejects the update with a signature mismatch.  This script
# verifies the signer certificate and aborts on a debug-signed APK.

set -euo pipefail

usage() {
    sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
}

apk=''
version=''
repo='michalkulik/koreader'
notes_file=''
title=''

while [[ $# -gt 0 ]]; do
    case "$1" in
        --apk) apk="${2:-}"; shift 2 ;;
        --version) version="${2:-}"; shift 2 ;;
        --repo) repo="${2:-}"; shift 2 ;;
        --notes-file) notes_file="${2:-}"; shift 2 ;;
        --title) title="${2:-}"; shift 2 ;;
        -h | --help) usage ;;
        *) echo "unknown argument: $1" >&2; usage ;;
    esac
done

[[ -n "${apk}" && -n "${version}" ]] || usage
[[ -f "${apk}" ]] || { echo "APK not found: ${apk}" >&2; exit 1; }
apk="$(realpath "${apk}")"
[[ "${version}" =~ ^v[0-9]{4}\.[0-9]{1,2}(\.[0-9]{1,2})?$ ]] || {
    echo "version must look like vYYYY.MM (got: ${version})" >&2
    exit 1
}

# Refuse to publish an APK signed with Android's throw-away debug key.  An
# update installed over an older KOReader build requires the same certificate
# as that older build.
expected_sha="${KOREADER_EXPECTED_SIGNER_SHA256:-78483177925e3d355d2aad8f348ec7bff4efd5261db8056bf8c0c920842cd4f6}"
sdk="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/.local/share/tools/android-sdk}}"
apksigner=""
if [[ -d "${sdk}/build-tools" ]]; then
    apksigner="$(find "${sdk}/build-tools" -mindepth 2 -maxdepth 2 -type f -name apksigner \
        | sort -V | tail -1)"
fi
[[ -n "${apksigner}" ]] || apksigner="$(command -v apksigner || true)"
[[ -n "${apksigner}" ]] || {
    echo "apksigner not found; cannot verify APK signing key." >&2
    exit 1
}
apk_sha="$("${apksigner}" verify --print-certs "${apk}" \
    | sed -n 's/^.*certificate SHA-256 digest: //p' | head -1)"
apk_sha="${apk_sha//:/}"
apk_sha="$(printf '%s' "${apk_sha}" | tr '[:upper:]' '[:lower:]')"
if [[ "${apk_sha}" != "${expected_sha}" ]]; then
    echo "ERROR: APK is not signed with the KOReader release key." >&2
    echo "  expected: ${expected_sha}" >&2
    echo "  actual:   ${apk_sha:-<none>}" >&2
    echo "Run: tools/sign-android-release.sh --apk $(basename "${apk}")" >&2
    exit 1
fi

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out_dir="${TMPDIR:-/tmp}/opencode/ota-assets-${version}"
mkdir -p "${out_dir}"

"${root_dir}/tools/make-ota-assets.py" \
    --apk "${apk}" \
    --version "${version}" \
    --out "${out_dir}" \
    --repo "${repo}"

sha_file="${apk}.sha256"
( cd "$(dirname "${apk}")" && sha256sum "$(basename "${apk}")" ) >"${sha_file}"

title="${title:-${version}}"
assets=(
    "${apk}"
    "${sha_file}"
    "${out_dir}/koreader-android-arm64-latest-stable"
    "${out_dir}/latest.json"
)

if gh release view "${version}" --repo "${repo}" >/dev/null 2>&1; then
    if [[ -n "${notes_file}" ]]; then
        gh release edit "${version}" --repo "${repo}" --title "${title}" \
            --latest --notes-file "${notes_file}"
    else
        gh release edit "${version}" --repo "${repo}" --title "${title}" --latest
    fi
else
    create_args=(
        "${version}"
        --repo "${repo}"
        --title "${title}"
        --latest
    )
    if [[ -n "${notes_file}" ]]; then
        create_args+=(--notes-file "${notes_file}")
    else
        create_args+=(--notes "KOReader fork release ${version}")
    fi
    gh release create "${create_args[@]}"
fi

gh release upload "${version}" --repo "${repo}" --clobber "${assets[@]}"

echo
echo "Published ${version}:"
for asset in "${assets[@]}"; do
    echo "  - $(basename "${asset}")"
done
echo
echo "OTA manifest:"
echo "  https://github.com/${repo}/releases/latest/download/koreader-android-arm64-latest-stable"
echo
"${root_dir}/tools/cleanup-built-releases.sh" --version "${version}" --tmp
