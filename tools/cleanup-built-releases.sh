#!/usr/bin/env bash
# Remove old locally built release artifacts, keeping only the requested
# version.  The published GitHub release remains the source of truth; these
# files are only build by-products on this host.
#
# Usage:
#   tools/cleanup-built-releases.sh                 # keep the latest git tag
#   tools/cleanup-built-releases.sh --version v2026.52
#   tools/cleanup-built-releases.sh --all           # remove every built artifact

set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${root_dir}"

version=""
keep_all=0
if [[ $# -gt 0 ]]; then
    case "$1" in
        --version)
            version="${2:-}"
            ;;
        --all)
            keep_all=1
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
fi

if [[ "${keep_all}" -eq 0 && -z "${version}" ]]; then
    version="$(git describe --tags --abbrev=0 2>/dev/null || true)"
fi
version="${version#v}"
[[ "${keep_all}" -eq 1 || -n "${version}" ]] || {
    echo "could not determine the release version; pass --version or --all" >&2
    exit 1
}

keep_tokens=()
if [[ "${keep_all}" -eq 0 ]]; then
    keep_tokens=("v${version}" "${version}.0")
fi

is_kept() {
    local filename="$1" token
    for token in "${keep_tokens[@]}"; do
        [[ "${filename}" == *"${token}"* ]] && return 0
    done
    return 1
}

removed=0
while IFS= read -r -d '' file; do
    filename="$(basename "${file}")"
    [[ "${keep_all}" -eq 0 ]] && is_kept "${filename}" && continue
    rm -f -- "${file}"
    removed=$((removed + 1))
done < <(find . -maxdepth 1 -type f \
    \( -name 'koreader-android-*' \
    -o -name 'koreader-kindle*' \
    -o -name 'koreader-mkulik_*' \) -print0)

if [[ "${keep_all}" -eq 1 ]]; then
    echo "Removed ${removed} built release artifacts."
else
    echo "Removed ${removed} old built release artifacts; kept ${version}."
fi
