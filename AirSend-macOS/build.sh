#!/bin/bash
set -e

APP_NAME="AirSend"
BUILD_DIR=".build/arm64-apple-macosx/debug"
EXECUTABLE_NAME="AirSend"
ICON_PATH="AppIcon.icns"
DIST_DIR="dist"
SPARKLE_FRAMEWORK_NAME="Sparkle.framework"
CODESIGN_ARGS=()

clean_bundle_xattrs() {
    local bundle_path="$1"
    xattr -cr "$bundle_path" 2>/dev/null || true
    xattr -d -r com.apple.FinderInfo "$bundle_path" 2>/dev/null || true
    xattr -d -r com.apple.fileprovider.fpfs#P "$bundle_path" 2>/dev/null || true
    xattr -d -r com.apple.macl "$bundle_path" 2>/dev/null || true
    xattr -d -r com.apple.provenance "$bundle_path" 2>/dev/null || true
    xattr -d -r com.apple.ResourceFork "$bundle_path" 2>/dev/null || true
    while IFS= read -r -d '' item; do
        xattr -c "$item" 2>/dev/null || true
    done < <(find -H "$bundle_path" -xattr -print0 2>/dev/null)

    local sparkle="$bundle_path/Contents/Frameworks/$SPARKLE_FRAMEWORK_NAME"
    for item in \
        "$bundle_path" \
        "$sparkle" \
        "$sparkle/Versions/B" \
        "$sparkle/Versions/B/Updater.app" \
        "$sparkle/Versions/B/XPCServices/Downloader.xpc" \
        "$sparkle/Versions/B/XPCServices/Installer.xpc" \
        "$sparkle/Versions/Current/Updater.app" \
        "$sparkle/Versions/Current/XPCServices/Downloader.xpc" \
        "$sparkle/Versions/Current/XPCServices/Installer.xpc"
    do
        [ -e "$item" ] && xattr -c "$item" 2>/dev/null || true
    done
}

find_sparkle_framework() {
    local swiftpm_framework="$BUILD_DIR/$SPARKLE_FRAMEWORK_NAME"
    local artifact_framework=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/$SPARKLE_FRAMEWORK_NAME"

    if [ -d "$swiftpm_framework" ]; then
        echo "$swiftpm_framework"
        return 0
    fi

    if [ -d "$artifact_framework" ]; then
        echo "$artifact_framework"
        return 0
    fi

    echo "❌ Missing Sparkle.framework. Run swift build first." >&2
    return 1
}

ensure_framework_rpath() {
    local executable_path="$1"
    local rpath="@executable_path/../Frameworks"

    if ! otool -l "$executable_path" | grep -q "$rpath"; then
        install_name_tool -add_rpath "$rpath" "$executable_path"
    fi
}

resolve_codesign_args() {
    local identity="${SIGNING_IDENTITY:-GetBackMyWindowsCert}"

    if security find-identity -v -p codesigning | grep -q "$identity"; then
        CODESIGN_ARGS=(--force --sign "$identity")
        if [[ "$identity" == Developer\ ID\ Application:* ]]; then
            CODESIGN_ARGS+=(--timestamp --options runtime)
        fi
    else
        echo "⚠️  Certificate '$identity' not found, using ad-hoc signing"
        CODESIGN_ARGS=(--force --sign -)
    fi
}

sign_path() {
    local path="$1"
    if [ -e "$path" ]; then
        codesign "${CODESIGN_ARGS[@]}" "$path"
    fi
}

sign_sparkle_framework() {
    local sparkle="$1"
    local version_dir="$sparkle/Versions/B"

    sign_path "$version_dir/Autoupdate"
    sign_path "$version_dir/Updater.app"
    sign_path "$version_dir/XPCServices/Downloader.xpc"
    sign_path "$version_dir/XPCServices/Installer.xpc"
    sign_path "$version_dir"
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
mkdir -p "$APP_BUNDLE/Contents/Frameworks"

# Copy Executable (Rename to match Info.plist CFBundleExecutable)
cp -X "$BUILD_DIR/$EXECUTABLE_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
ensure_framework_rpath "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Copy Info.plist
cp -X Info.plist "$APP_BUNDLE/Contents/Info.plist"

# Copy Icon
if [ ! -f "$ICON_PATH" ]; then
    echo "❌ Missing required app icon: $ICON_PATH" >&2
    exit 1
fi
cp -X "$ICON_PATH" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

SPARKLE_SOURCE=$(find_sparkle_framework)
SPARKLE_DEST="$APP_BUNDLE/Contents/Frameworks/$SPARKLE_FRAMEWORK_NAME"
rm -rf "$SPARKLE_DEST"
/usr/bin/ditto "$SPARKLE_SOURCE" "$SPARKLE_DEST"
chmod -R a+rX "$SPARKLE_DEST"

clean_bundle_xattrs "$APP_BUNDLE"

# Sign Sparkle's nested helpers before signing the app bundle.
resolve_codesign_args
sign_sparkle_framework "$SPARKLE_DEST"
codesign "${CODESIGN_ARGS[@]}" --deep "$APP_BUNDLE"
clean_bundle_xattrs "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

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
