#!/bin/bash
# Builds a release copy of Tote, zips it, and prints the checksum for the Homebrew cask.
# Usage: ./release.sh 1.0.0 [scheme]
set -euo pipefail

VERSION="${1:?Usage: ./release.sh <version> [scheme]   e.g. ./release.sh 1.0.0}"
SCHEME="${2:-Tote}"
PROJECT="Tote.xcodeproj"

echo "==> Building $SCHEME $VERSION (Release)"
rm -rf build
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath build \
  MACOSX_DEPLOYMENT_TARGET=14.0 \
  CODE_SIGN_IDENTITY="-" \
  build | tail -n 20

APP="build/Build/Products/Release/Tote.app"
if [ ! -d "$APP" ]; then
  echo "Could not find $APP. Run 'xcodebuild -list -project $PROJECT' and pass the right scheme name as the second argument." >&2
  exit 1
fi

echo "==> Checking the signature"
codesign --verify --deep --strict "$APP" && echo "signature OK"

ZIP="Tote-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo
echo "==> Done: $ZIP"
echo "sha256: $(shasum -a 256 "$ZIP" | awk '{print $1}')"
