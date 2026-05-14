#!/bin/bash
set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/build"
ARCHIVE_PATH="$BUILD_DIR/ProxyHelper.xcarchive"
APP_PATH="$BUILD_DIR/ProxyHelper.app"

cd "$REPO_ROOT"

echo "==> Cleaning build dir"
rm -rf "$ARCHIVE_PATH" "$APP_PATH" "$BUILD_DIR"/ProxyHelper-*.zip

VERSION=$(git describe --tags --abbrev=0 2>/dev/null || echo "local")
MARKETING_VERSION="${VERSION#v}"

echo "==> Archiving (version: $MARKETING_VERSION)"
xcodebuild archive \
    -project ProxyHelper.xcodeproj \
    -scheme ProxyHelper \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    MACOSX_DEPLOYMENT_TARGET=15.0 \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_ALLOWED=NO \
    MARKETING_VERSION="$MARKETING_VERSION"

echo "==> Packaging"
cp -r "$ARCHIVE_PATH/Products/Applications/ProxyHelper.app" "$APP_PATH"
ZIP_NAME="ProxyHelper-${VERSION}.zip"
cd "$BUILD_DIR"
zip -r --symlinks "$ZIP_NAME" ProxyHelper.app

echo "==> Done: build/$ZIP_NAME ($(du -sh "$ZIP_NAME" | cut -f1))"
