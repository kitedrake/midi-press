#!/bin/sh
# Builds MidiPress.app into build/. Uses Xcode's toolchain when Xcode is installed (the Command Line Tools don't
# include the macOS 26 SDK that SwiftUI's Liquid Glass needs).
#
# Signing is ad-hoc unless SIGN_IDENTITY names a code-signing identity. macOS ties the Accessibility permission
# (which MidiPress needs to press keys) to the app's signature: with ad-hoc signing every rebuild counts as a new
# app and has to be allowed again; with a stable identity ("Apple Development: …") the permission stays. A
# "Developer ID Application" identity (releases) also turns on the hardened runtime and a secure timestamp, as
# notarization requires.
#
# A plain ./build.sh has no update feed, so it never checks for updates. Release builds also set (see "Updates and
# releases" in the README):
#   UPDATE_FEED_URL    the Sparkle update feed, e.g. https://example.com/updates/midipress/appcast.xml
#   UPDATE_PUBLIC_KEY  the EdDSA public key (base64) whose private half signs the updates
set -eu
cd "$(dirname "$0")"
if [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
version="${APP_VERSION:-$(tr -d '[:space:]' < VERSION)}"   # APP_VERSION: for update tests only
identity="${SIGN_IDENTITY:--}"
feed="${UPDATE_FEED_URL:-}"
key="${UPDATE_PUBLIC_KEY:-}"
if { [ -n "$feed" ] && [ -z "$key" ]; } || { [ -z "$feed" ] && [ -n "$key" ]; }; then
  echo "Set both UPDATE_FEED_URL and UPDATE_PUBLIC_KEY, or neither." >&2
  exit 1
fi

sign_code() {
  case "$identity" in
    "Developer ID"*) codesign --force --sign "$identity" --options runtime --timestamp "$1" ;;
    *) codesign --force --sign "$identity" "$1" ;;
  esac
}

# The packages are public: --disable-keychain stops SwiftPM looking for github.com passwords in the Keychain when it
# downloads Sparkle's framework, which makes macOS ask to use whatever GitHub credentials are saved there.
xcrun swift build --disable-keychain -c release --product MidiPress
bindir="$(xcrun swift build --disable-keychain -c release --show-bin-path)"
app="build/MidiPress.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
cp "$bindir/MidiPress" "$app/Contents/MacOS/MidiPress"
# Sparkle, for in-app updates. MidiPress isn't sandboxed, so Sparkle's XPC services aren't needed.
framework="$app/Contents/Frameworks/Sparkle.framework"
ditto "$bindir/Sparkle.framework" "$framework"
rm -rf "$framework/XPCServices" "$framework/Versions/B/XPCServices"
if ! otool -l "$app/Contents/MacOS/MidiPress" | grep -q "@executable_path/../Frameworks"; then
  install_name_tool -add_rpath @executable_path/../Frameworks "$app/Contents/MacOS/MidiPress"
fi
updates=""
if [ -n "$feed" ]; then
  updates="<key>SUFeedURL</key><string>$feed</string>
  <key>SUPublicEDKey</key><string>$key</string>"
fi
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"; fi
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>MidiPress</string>
  <key>CFBundleDisplayName</key><string>MidiPress</string>
  <key>CFBundleIdentifier</key><string>com.kitedrake.midipress</string>
  <key>CFBundleExecutable</key><string>MidiPress</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${version}</string>
  <key>CFBundleVersion</key><string>${version}</string>
  $updates
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MidiPress by omso. GNU GPL v3 or later.</string>
</dict>
</plist>
PLIST
# Sign from the inside out.
sign_code "$framework/Versions/B/Autoupdate"
sign_code "$framework/Versions/B/Updater.app"
sign_code "$framework"
sign_code "$app"
echo "Built $(pwd)/$app"
