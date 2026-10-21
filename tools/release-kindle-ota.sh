#!/usr/bin/env bash
# Publish a Kindle OTA update (kotasync manifest + update.tar.xz).
#
# Usage:
#   tools/release-kindle-ota.sh --version v2026.41
#   tools/release-kindle-ota.sh --version v2026.41 --model kindlepw2
#
# Kindle 10 / KT4 (KPM target kindlehf) must use --model kindlehf, which is
# the default.  kindlepw2 is only for older devices.
#
# The release must already contain koreader-<model>-<version>.zip, e.g.:
#   koreader-kindlehf-v2026.41.zip
#
# This creates and uploads:
#   koreader-<model>-<version>.tar.xz
#   koreader-<model>-<version>.kotasync
#   koreader-<model>-latest-stable.kotasync
#
# KOReader's built-in OTA on Kindle fetches
#   /releases/latest/download/koreader-<model>-latest-stable.kotasync

set -euo pipefail

version=''
model="${KINDLE_OTA_MODEL:-kindlehf}"
repo="${KINDLE_OTA_REPO:-michalkulik/koreader}"
no_upload=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) version="${2:-}"; shift 2 ;;
        --model) model="${2:-}"; shift 2 ;;
        --repo) repo="${2:-}"; shift 2 ;;
        --no-upload) no_upload=1; shift ;;
        -h | --help)
            sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

[[ -n "${version}" ]] || {
    echo "usage: $0 --version vYYYY.MM [--model kindlehf|kindlepw2]" >&2
    exit 1
}
[[ "${version}" =~ ^v[0-9]{4}\.[0-9]{1,2}(\.[0-9]{1,2})?$ ]] || {
    echo "version must look like vYYYY.MM (got: ${version})" >&2
    exit 1
}
case "${model}" in
    kindlehf | kindlepw2 | kindle | kindle-legacy) ;;
    *)
        echo "unsupported Kindle model: ${model}" >&2
        exit 1
        ;;
esac

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${root_dir}"

zip="koreader-${model}-${version}.zip"
[[ -f "${zip}" ]] || {
    echo "missing release archive: ${zip}" >&2
    echo "build it first with: ./kodev release -i ${model}" >&2
    exit 1
}

out_dir="${TMPDIR:-/tmp}/opencode/kindle-ota-${version}-${model}"
mkdir -p "${out_dir}"
tar_xz="${out_dir}/koreader-${model}-${version}.tar.xz"
kotasync="${out_dir}/koreader-${model}-${version}.kotasync"
latest="${out_dir}/koreader-${model}-latest-stable.kotasync"

./tools/mkrelease.sh "${tar_xz}" "${zip}"

appimage="$(find base/kotasync -maxdepth 1 -name 'kotasync-*.AppImage' -type f | sort -V | tail -1)"
if [[ -z "${appimage}" ]]; then
    echo "kotasync AppImage not found; building it…" >&2
    make -C base/kotasync -j"$(getconf _NPROCESSORS_ONLN)"
    appimage="$(find base/kotasync -maxdepth 1 -name 'kotasync-*.AppImage' -type f | sort -V | tail -1)"
fi
[[ -n "${appimage}" ]] || {
    echo "kotasync AppImage still missing" >&2
    exit 1
}

"${appimage}" --appimage-extract-and-run make "${tar_xz}" "${kotasync}"
cp -f "${kotasync}" "${latest}"

echo
echo "Created OTA assets for ${model} ${version}:"
ls -lh "${tar_xz}" "${kotasync}" "${latest}"

if [[ "${no_upload}" -eq 0 ]]; then
    gh release upload "${version}" \
        "${tar_xz}" "${kotasync}" "${latest}" \
        --repo "${repo}" --clobber
    echo
    echo "Uploaded to release ${version}."
    echo "OTA manifest:"
    echo "  https://github.com/${repo}/releases/latest/download/$(basename "${latest}")"
fi

./tools/cleanup-built-releases.sh --version "${version}" --tmp
