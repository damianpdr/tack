#!/bin/bash
# Builds build/Voice.app (release) and signs it. `--install` also replaces /Applications/Voice.app.
set -euo pipefail

cd "$(dirname "$0")/.."

install=false
for arg in "$@"; do
    case "$arg" in
        --install) install=true ;;
        *) echo "usage: $0 [--install]" >&2; exit 64 ;;
    esac
done

scratch=.build-release
swift build -c release --product Voice --scratch-path "$scratch"
binary="$(swift build -c release --product Voice --scratch-path "$scratch" --show-bin-path)/Voice"

app=build/Voice.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$binary" "$app/Contents/MacOS/Voice"

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.damian.voice</string>
    <key>CFBundleName</key>
    <string>Voice</string>
    <key>CFBundleDisplayName</key>
    <string>Voice</string>
    <key>CFBundleExecutable</key>
    <string>Voice</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Voice records your speech while you hold a recording session and turns it into a prompt.</string>
</dict>
</plist>
PLIST

entitlements="$scratch/Voice.entitlements"
cat > "$entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key>
    <true/>
</dict>
</plist>
PLIST

# Ad-hoc signatures change every build, so macOS drops Accessibility/Screen Recording grants; a stable identity keeps them.
default_identity=-
if security find-identity -p codesigning | grep -q '"Voice Local Signing"'; then
    default_identity="Voice Local Signing"
fi
identity="${VOICE_SIGN_IDENTITY:-$default_identity}"
codesign --force --options runtime --timestamp=none --entitlements "$entitlements" --sign "$identity" "$app"
codesign --verify --strict "$app"
echo "Built $app (signed with ${identity/#-/ad-hoc})"

if $install; then
    # SIGTERM instead of `osascript quit`, which blocks on an Automation consent prompt when run from a terminal.
    if pkill -x Voice; then
        for _ in $(seq 1 50); do
            pgrep -x Voice >/dev/null || break
            sleep 0.1
        done
        pkill -9 -x Voice || true
    fi
    rm -rf /Applications/Voice.app
    cp -R "$app" /Applications/Voice.app
    echo "Installed /Applications/Voice.app"
fi
