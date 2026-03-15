#!/bin/bash
set -e

APP_NAME="AirSend"
BUILD_DIR=".build/arm64-apple-macosx/debug"
EXECUTABLE_NAME="AirSend"

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

echo "📦 Packaging $APP_NAME.app..."
rm -rf "$APP_NAME.app"
mkdir -p "$APP_NAME.app/Contents/MacOS"
mkdir -p "$APP_NAME.app/Contents/Resources"

# Copy Executable (Rename to match Info.plist CFBundleExecutable)
cp -X "$BUILD_DIR/$EXECUTABLE_NAME" "$APP_NAME.app/Contents/MacOS/$APP_NAME"

# Copy Info.plist
cp -X Info.plist "$APP_NAME.app/Contents/Info.plist"

# Copy Icon
if [ -f "AppIcon.icns" ]; then
    cp -X AppIcon.icns "$APP_NAME.app/Contents/Resources/AppIcon.icns"
fi

# Remove quarantine attribute (fix "App is damaged" error)
clean_bundle_xattrs "$APP_NAME.app"

# Sign with persistent local certificate (avoids re-granting permissions on each build)
SIGNING_IDENTITY="GetBackMyWindowsCert"
if security find-identity -v -p codesigning | grep -q "$SIGNING_IDENTITY"; then
    clean_bundle_xattrs "$APP_NAME.app"
    codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP_NAME.app"
else
    echo "⚠️  Certificate '$SIGNING_IDENTITY' not found, using ad-hoc signing"
    clean_bundle_xattrs "$APP_NAME.app"
    # Sign the App (Ad-hoc signature for local running)
    codesign --force --deep --sign - "$APP_NAME.app"
fi

echo "✅ Build Complete!"
echo "📂 Location: $(pwd)/$APP_NAME.app"

# 🚀 Kill existing process and restart (as per user instruction)
echo "🔄 Restarting $APP_NAME..."
pkill -x "$APP_NAME" || true
open "$APP_NAME.app"
echo "✨ $APP_NAME restarted successfully."
