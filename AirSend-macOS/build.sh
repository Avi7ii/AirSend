#!/bin/bash
set -e

APP_NAME="AirSend"
BUILD_DIR=".build/arm64-apple-macosx/debug"
EXECUTABLE_NAME="AirSend"
ICON_PATH="AppIcon.icns"
DIST_DIR="dist"

clean_bundle_xattrs() {
    local bundle_path="$1"
    xattr -cr "$bundle_path" 2>/dev/null || true
    xattr -d -r com.apple.FinderInfo "$bundle_path" 2>/dev/null || true
    xattr -d -r com.apple.fileprovider.fpfs#P "$bundle_path" 2>/dev/null || true
    xattr -d -r com.apple.macl "$bundle_path" 2>/dev/null || true
    xattr -d -r com.apple.provenance "$bundle_path" 2>/dev/null || true
    xattr -d -r com.apple.ResourceFork "$bundle_path" 2>/dev/null || true
}

echo "🚀 Building $APP_NAME (Debug Mode)..."
swift build -c debug

TMP_ROOT=$(mktemp -d /tmp/airsend-build.XXXXXX)
APP_BUNDLE="$TMP_ROOT/$APP_NAME.app"
DIST_BUNDLE="$DIST_DIR/$APP_NAME.app"

cleanup() {
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

echo "📦 Packaging $APP_NAME.app..."
rm -rf "$APP_NAME.app" "$DIST_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy Executable (Rename to match Info.plist CFBundleExecutable)
cp -X "$BUILD_DIR/$EXECUTABLE_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Copy Info.plist
cp -X Info.plist "$APP_BUNDLE/Contents/Info.plist"

# Copy Icon
if [ ! -f "$ICON_PATH" ]; then
    echo "❌ Missing required app icon: $ICON_PATH" >&2
    exit 1
fi
cp -X "$ICON_PATH" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

clean_bundle_xattrs "$APP_BUNDLE"

# Sign with persistent local certificate (avoids re-granting permissions on each build)
SIGNING_IDENTITY="GetBackMyWindowsCert"
if security find-identity -v -p codesigning | grep -q "$SIGNING_IDENTITY"; then
    codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP_BUNDLE"
else
    echo "⚠️  Certificate '$SIGNING_IDENTITY' not found, using ad-hoc signing"
    codesign --force --deep --sign - "$APP_BUNDLE"
fi

mkdir -p "$DIST_DIR"
/usr/bin/ditto "$APP_BUNDLE" "$DIST_BUNDLE"
clean_bundle_xattrs "$DIST_BUNDLE"

# Keep a repo-local copy for convenience.
/usr/bin/ditto "$APP_BUNDLE" "$APP_NAME.app"
clean_bundle_xattrs "$APP_NAME.app"

echo "✅ Build Complete!"
echo "📂 Location: $(pwd)/$DIST_BUNDLE"

# 🚀 Kill existing process and restart (as per user instruction)
echo "🔄 Restarting $APP_NAME..."
pkill -x "$APP_NAME" || true
open "$DIST_BUNDLE"
echo "✨ $APP_NAME restarted successfully."
