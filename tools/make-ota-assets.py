#!/usr/bin/env python3
"""Generate in-app OTA metadata for a KOReader fork Android release.

KOReader's built-in updater (``link`` OTA type on Android) downloads a small
text manifest named ``koreader-<model>-latest-<channel>``.  Its first line is
the APK asset name, which is then resolved relative to the same release URL.
``latest.json`` is the richer, future-proof metadata file.

Example:

    tools/make-ota-assets.py --apk koreader-android-arm64-v2026.14.apk \
        --version v2026.14 --out /tmp/opencode/ota-assets

Then attach both generated files and the APK to the GitHub release:

    gh release create v2026.14 ... \
        koreader-android-arm64-v2026.14.apk \
        /tmp/opencode/ota-assets/koreader-android-arm64-latest-stable \
        /tmp/opencode/ota-assets/latest.json
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys


def normalized_version(version: str) -> int:
    match = re.fullmatch(r"v(\d{4})\.(\d{1,2})(?:\.(\d{1,2}))?", version)
    if not match:
        raise SystemExit(f"unsupported version format: {version!r} (expected vYYYY.MM[.P])")
    year = int(match.group(1))
    month = int(match.group(2))
    point = int(match.group(3) or 0)
    return ((year * 100) + month) * 1_000_000 + point * 10_000


def sha256(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apk", required=True, help="signed APK path")
    parser.add_argument("--version", required=True, help="release tag, e.g. v2026.14")
    parser.add_argument("--out", default="ota-assets", help="output directory")
    parser.add_argument("--repo", default="michalkulik/koreader")
    parser.add_argument("--model", default="android-arm64")
    parser.add_argument("--abi", default="arm64-v8a")
    parser.add_argument("--channel", default="stable")
    args = parser.parse_args()

    if not os.path.isfile(args.apk):
        raise SystemExit(f"APK not found: {args.apk}")

    filename = os.path.basename(args.apk)
    url = f"https://github.com/{args.repo}/releases/download/{args.version}/{filename}"
    metadata = {
        "version": args.version,
        "versionCode": normalized_version(args.version),
        "url": url,
        "sha256": sha256(args.apk),
        "size": os.path.getsize(args.apk),
        "abi": args.abi,
        "filename": filename,
    }

    os.makedirs(args.out, exist_ok=True)
    manifest = os.path.join(args.out, f"koreader-{args.model}-latest-{args.channel}")
    with open(manifest, "w", encoding="utf-8") as handle:
        handle.write(filename + "\n")
    latest = os.path.join(args.out, "latest.json")
    with open(latest, "w", encoding="utf-8") as handle:
        json.dump(metadata, handle, ensure_ascii=False, indent=2)
        handle.write("\n")

    print(manifest)
    print(latest)
    print(json.dumps(metadata, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
