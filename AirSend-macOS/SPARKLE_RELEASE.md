# AirSend Sparkle Release Notes

AirSend macOS uses Sparkle 2 for automatic updates, following the CodexBar release pattern.

## Keys

- `SUPublicEDKey` is stored in `Info.plist`.
- The private Ed25519 key is stored in the macOS Keychain under the Sparkle account `AirSend`.
- To print the public key again:

```bash
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account AirSend -p
```

## Appcast

The app reads:

```text
https://raw.githubusercontent.com/Avi7ii/AirSend/main/appcast.xml
```

To generate a signed appcast after creating a release zip:

```bash
mkdir -p release-assets
cp AirSend-macOS.zip release-assets/
AIRSEND_DOWNLOAD_URL_PREFIX="https://github.com/Avi7ii/AirSend/releases/download/v3.6.0" \
  ./script/make_appcast.sh release-assets
```

Commit the updated root `appcast.xml` after publishing the matching GitHub release asset.

## Release Checklist

- Build the `.app` with Sparkle embedded under `Contents/Frameworks`.
- Sign Sparkle's `Autoupdate`, `Updater.app`, `Downloader.xpc`, and `Installer.xpc` before signing the app bundle.
- Zip the signed app with `ditto`, not `zip`, to avoid AppleDouble files.
- Publish the zip on GitHub Releases.
- Run `script/make_appcast.sh` with the release asset URL prefix.
- Verify the appcast enclosure URL returns HTTP 200.
- Keep one previous signed build installed and test Sparkle updating into the new build.
