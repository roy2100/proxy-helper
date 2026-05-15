#!/bin/bash
set -e

REPO="roy2100/proxy-helper"
APP_NAME="ProxyHelper.app"
INSTALL_DIR="/Applications"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "==> Fetching latest release info"
API_URL="https://api.github.com/repos/$REPO/releases/latest"
RELEASE_JSON="$(curl -fsSL "$API_URL")"

TAG="$(echo "$RELEASE_JSON" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)"
ASSET_URL="$(echo "$RELEASE_JSON" \
    | grep -o '"browser_download_url": *"[^"]*\.zip"' \
    | sed 's/.*: *"\([^"]*\)".*/\1/' \
    | head -1)"

if [ -z "$ASSET_URL" ]; then
    echo "Error: no .zip asset found in latest release"
    exit 1
fi

echo "==> Latest: $TAG"
echo "==> Downloading $ASSET_URL"
ZIP_PATH="$TMP_DIR/release.zip"
curl -fL --progress-bar -o "$ZIP_PATH" "$ASSET_URL"

echo "==> Unzipping"
unzip -q "$ZIP_PATH" -d "$TMP_DIR"

SRC_APP="$TMP_DIR/$APP_NAME"
if [ ! -d "$SRC_APP" ]; then
    SRC_APP="$(find "$TMP_DIR" -maxdepth 2 -name "*.app" -type d | head -1)"
fi
if [ -z "$SRC_APP" ] || [ ! -d "$SRC_APP" ]; then
    echo "Error: $APP_NAME not found in archive"
    exit 1
fi

DEST="$INSTALL_DIR/$APP_NAME"
if [ -d "$DEST" ]; then
    echo "==> Removing existing $DEST"
    if ! rm -rf "$DEST" 2>/dev/null; then
        sudo rm -rf "$DEST"
    fi
fi

echo "==> Moving to $DEST"
if ! mv "$SRC_APP" "$DEST" 2>/dev/null; then
    sudo mv "$SRC_APP" "$DEST"
fi

echo "==> Clearing quarantine attribute"
if ! xattr -dr com.apple.quarantine "$DEST" 2>/dev/null; then
    sudo xattr -dr com.apple.quarantine "$DEST" || true
fi

echo "==> Done: $DEST ($TAG)"
echo "    Launch with: open \"$DEST\""
