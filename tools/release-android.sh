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
