#!/usr/bin/env bash
# Build the app with code signing disabled.
#
# usage: build_app.sh [configuration] [sdk]
#
# Signing is forced off across the board: the runner has no Apple ID, and the
# IPA is re-signed by SideStore/AltStore/Sideloadly on the way onto the device.
# -target rather than -scheme, because the project ships no shared .xcscheme;
# SYMROOT rather than -derivedDataPath, which xcodebuild rejects without one.
set -euo pipefail

CONFIGURATION=${1:-Release}
SDK=${2:-iphoneos}

# The Cast SDK is not committed; make sure it is there before linking.
"$(dirname "$0")/fetch_cast_sdk.sh"

xcodebuild \
  -project Audioble.xcodeproj \
  -target Audioble \
  -configuration "$CONFIGURATION" \
  -sdk "$SDK" \
  SYMROOT="$PWD/build" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGN_ENTITLEMENTS="" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="" \
  ONLY_ACTIVE_ARCH=NO \
  COMPILER_INDEX_STORE_ENABLE=NO \
  build
