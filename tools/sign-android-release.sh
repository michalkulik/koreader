#!/usr/bin/env bash
# Sign a KOReader Android release APK with the fork's stable signing key.
#
# `kodev release android-arm64` produces a debug-signed APK.  Android will
# refuse to install a new build over an existing one unless both APKs are
# signed with the *same* certificate, so every release APK must be re-signed
# with the key used by the previous release.
#
# Usage:
#   tools/sign-android-release.sh --apk koreader-android-arm64-v2026.39.apk
#   tools/sign-android-release.sh --apk build.apk --out signed.apk
#
# The keystore and credentials default to:
#   ~/.local/share/signing/koreader/koreader-release.jks
#   ~/.local/share/signing/koreader/credentials.txt
#
# They can be overridden with:
#   KOREADER_KEYSTORE, KOREADER_KEYSTORE_CREDENTIALS,
#   KOREADER_KEY_ALIAS, KOREADER_KEYSTORE_PASS, KOREADER_KEY_PASS,
#   KOREADER_EXPECTED_SIGNER_SHA256
#
# The expected certificate defaults to the fork's release key so that a
# debug-signed or wrong-key APK is rejected before publishing.

set -euo pipefail

apk=''
out=''
keystore="${KOREADER_KEYSTORE:-$HOME/.local/share/signing/koreader/koreader-release.jks}"
credentials="${KOREADER_KEYSTORE_CREDENTIALS:-$HOME/.local/share/signing/koreader/credentials.txt}"
alias="${KOREADER_KEY_ALIAS:-}"
storepass="${KOREADER_KEYSTORE_PASS:-}"
keypass="${KOREADER_KEY_PASS:-}"
expected_sha="${KOREADER_EXPECTED_SIGNER_SHA256:-78483177925e3d355d2aad8f348ec7bff4efd5261db8056bf8c0c920842cd4f6}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --apk) apk="${2:-}"; shift 2 ;;
        --out) out="${2:-}"; shift 2 ;;
        --keystore) keystore="${2:-}"; shift 2 ;;
        --credentials) credentials="${2:-}"; shift 2 ;;
        --alias) alias="${2:-}"; shift 2 ;;
        -h | --help)
            sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

[[ -n "${apk}" && -f "${apk}" ]] || {
    echo "APK not found: ${apk:-<missing --apk>}" >&2
    exit 1
}
[[ -f "${keystore}" ]] || {
    echo "Keystore not found: ${keystore}" >&2
    exit 1
}

if [[ -z "${storepass}" || -z "${keypass}" || -z "${alias}" ]]; then
    [[ -f "${credentials}" ]] || {
        echo "Credentials not found: ${credentials}" >&2
        exit 1
    }
    storepass="${storepass:-$(sed -n 's/^storepass=//p' "${credentials}" | head -1)}"
    keypass="${keypass:-$(sed -n 's/^keypass=//p' "${credentials}" | head -1)}"
    alias="${alias:-$(sed -n 's/^alias=//p' "${credentials}" | head -1)}"
fi

[[ -n "${storepass}" && -n "${keypass}" && -n "${alias}" ]] || {
    echo "Could not read keystore password/key password/alias." >&2
    exit 1
}

sdk="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/.local/share/tools/android-sdk}}"
find_tool() {
    local name="$1"
    if [[ -n "${sdk}" && -d "${sdk}/build-tools" ]]; then
        find "${sdk}/build-tools" -mindepth 2 -maxdepth 2 -type f -name "${name}" \
            | sort -V | tail -1
    fi
}
apksigner="$(find_tool apksigner)"
zipalign="$(find_tool zipalign)"
if [[ -z "${apksigner}" || ! -x "${apksigner}" ]]; then
    apksigner="$(command -v apksigner || true)"
fi
if [[ -z "${zipalign}" || ! -x "${zipalign}" ]]; then
    zipalign="$(command -v zipalign || true)"
fi
[[ -n "${apksigner}" && -x "${apksigner}" ]] || {
    echo "apksigner not found (set ANDROID_SDK_ROOT)." >&2
    exit 1
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT
aligned="${tmpdir}/aligned.apk"
signed="${tmpdir}/signed.apk"

# Alignment must happen before signing; signing afterwards would invalidate
# the signature.
if [[ -n "${zipalign}" && -x "${zipalign}" ]]; then
    "${zipalign}" -p -f 4 "${apk}" "${aligned}"
else
    cp -f "${apk}" "${aligned}"
fi

"${apksigner}" sign \
    --ks "${keystore}" \
    --ks-key-alias "${alias}" \
    --ks-pass "pass:${storepass}" \
    --key-pass "pass:${keypass}" \
    --out "${signed}" \
    "${aligned}"

actual_sha="$("${apksigner}" verify --print-certs "${signed}" \
    | sed -n 's/^.*certificate SHA-256 digest: //p' | head -1)"
actual_sha="${actual_sha//:/}"
actual_sha="$(printf '%s' "${actual_sha}" | tr '[:upper:]' '[:lower:]')"
if [[ "${actual_sha}" != "${expected_sha}" ]]; then
    echo "ERROR: unexpected signing certificate." >&2
    echo "  expected: ${expected_sha}" >&2
    echo "  actual:   ${actual_sha:-<none>}" >&2
    exit 1
fi

if [[ -n "${out}" ]]; then
    cp -f "${signed}" "${out}"
else
    cp -f "${signed}" "${apk}"
fi

echo "Signed with the release key:"
"${apksigner}" verify --print-certs "${out:-${apk}}" \
    | grep -E 'Signer.*certificate (DN|SHA-256)'
