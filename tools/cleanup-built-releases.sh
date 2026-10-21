#!/usr/bin/env bash
# Remove old locally built release artifacts, keeping only the requested
# version.  Published GitHub releases remain the source of truth; these files
# are only build by-products on this host.
#
# Usage:
#   tools/cleanup-built-releases.sh                 # keep the latest git tag
#   tools/cleanup-built-releases.sh --version v2026.52
#   tools/cleanup-built-releases.sh --all           # remove every built artifact
#   tools/cleanup-built-releases.sh --tmp           # also clean /tmp/opencode

set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${root_dir}"

version=""
keep_all=0
clean_tmp=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            version="${2:-}"
            shift 2
            ;;
        --all)
            keep_all=1
            shift
            ;;
        --tmp)
            clean_tmp=1
            shift
            ;;
        -h | --help)
            sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

if [[ "${keep_all}" -eq 0 && -z "${version}" ]]; then
    version="$(git describe --tags --abbrev=0 2>/dev/null || true)"
fi
version="${version#v}"
[[ "${keep_all}" -eq 1 || -n "${version}" ]] || {
    echo "could not determine the release version; pass --version or --all" >&2
    exit 1
}

short_version="${version##*.}"
keep_tokens=()
if [[ "${keep_all}" -eq 0 ]]; then
    keep_tokens=("v${version}" "${version}.0")
fi

is_kept() {
    local filename="$1" token
    for token in "${keep_tokens[@]}"; do
        [[ "${filename}" == *"${token}"* ]] && return 0
    done
    # Manual KPM package directories use only the last version component.
    [[ "${filename}" == "kpm-koreader-hf-${short_version}" ]] && return 0
    return 1
}

remove_old() {
    local directory="$1"
    shift
    [[ -d "${directory}" ]] || return 0
    while IFS= read -r -d '' entry; do
        filename="$(basename "${entry}")"
        [[ "${keep_all}" -eq 0 ]] && is_kept "${filename}" && continue
        rm -rf -- "${entry}"
        removed=$((removed + 1))
    done < <(find "${directory}" -maxdepth 1 "$@" -print0)
}

removed=0
remove_old "${root_dir}" -type f \
    \( -name 'koreader-android-*' \
    -o -name 'koreader-kindle*' \
    -o -name 'koreader-mkulik_*' \)

if [[ "${keep_all}" -eq 1 && "${clean_tmp}" -eq 0 ]]; then
    echo "Removed ${removed} built release artifacts."
elif [[ "${keep_all}" -eq 1 ]]; then
    tmp_root="${TMPDIR:-/tmp}/opencode"
    remove_old "${tmp_root}" \
        \( -name 'koreader-android-*' -o -name 'koreader-kindle*' \
        -o -name 'koreader-mkulik_*' -o -name 'kindle-ota-*' \
        -o -name 'ota-assets-*' -o -name 'kpm-koreader-hf-*' \)
    echo "Removed ${removed} built release artifacts (including temporary files)."
else
    if [[ "${clean_tmp}" -eq 1 ]]; then
        tmp_root="${TMPDIR:-/tmp}/opencode"
        remove_old "${tmp_root}" \
            \( -name 'koreader-android-*' -o -name 'koreader-kindle*' \
            -o -name 'koreader-mkulik_*' -o -name 'kindle-ota-*' \
            -o -name 'ota-assets-*' -o -name 'kpm-koreader-hf-*' \)
    fi
    echo "Removed ${removed} old built release artifacts; kept ${version}."
fi
