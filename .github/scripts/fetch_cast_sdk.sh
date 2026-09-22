#!/usr/bin/env bash
# Fetch the Google Cast SDK into Vendor/.
#
# The SDK is a closed-source binary framework that Google distributes as a zip,
# so it is downloaded rather than committed: the repository stays source-only
# and the download is a couple of seconds on a runner.
#
# usage: fetch_cast_sdk.sh [version]
set -euo pipefail

VERSION=${1:-4.8.3}
DEST=Vendor/GoogleCast.xcframework

if [ -d "$DEST" ]; then
  echo "GoogleCast.xcframework already present"
  exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

URL="https://dl.google.com/dl/chromecast/sdk/ios/GoogleCastSDK-ios-${VERSION}_dynamic.zip"
echo "Downloading $URL"
curl -fsSL --retry 3 --retry-delay 2 -o "$WORK/cast.zip" "$URL"
unzip -q "$WORK/cast.zip" -d "$WORK/unpacked"

SRC=$(find "$WORK/unpacked" -maxdepth 2 -name GoogleCast.xcframework -type d | head -1)
if [ -z "$SRC" ]; then
  echo "::error::GoogleCast.xcframework not found inside the download"
  exit 1
fi

mkdir -p Vendor
cp -R "$SRC" "$DEST"
echo "Installed $DEST"
du -sh "$DEST"
