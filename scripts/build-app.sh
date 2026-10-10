#!/bin/bash
# Builds build/Tack.app (release) and signs it. `--install` also replaces /Applications/Tack.app.
set -euo pipefail

cd "$(dirname "$0")/.."

install=false
for arg in "$@"; do
    case "$arg" in
        --install) install=true ;;
        *) echo "usage: $0 [--install]" >&2; exit 64 ;;
    esac
done

# VERSION is the single source of truth for the marketing version; the build number counts commits.
version="$(tr -d '[:space:]' < VERSION)"
build_number="$(git rev-list --count HEAD 2>/dev/null || true)"
[ -n "$build_number" ] && [ "$build_number" != 0 ] || build_number=1

scratch=.build-release
swift build -c release --product Tack --scratch-path "$scratch"
binary="$(swift build -c release --product Tack --scratch-path "$scratch" --show-bin-path)/Tack"

app=build/Tack.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/Tack"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.damianpdr.tack</string>
    <key>CFBundleName</key>
    <string>Tack</string>
    <key>CFBundleDisplayName</key>
    <string>Tack</string>
    <key>CFBundleExecutable</key>
    <string>Tack</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleShortVersionString</key>
    <string>$version</string>
    <key>CFBundleVersion</key>
    <string>$build_number</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Tack records your speech during a recording and turns it into a prompt.</string>
</dict>
</plist>
PLIST

entitlements="$scratch/Tack.entitlements"
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
# "Voice Local Signing" is the identity created before the rename; either keeps grants stable.
for name in "Tack Local Signing" "Voice Local Signing"; do
    if security find-identity -p codesigning | grep -q "\"$name\""; then
        default_identity="$name"
        break
    fi
done
identity="${TACK_SIGN_IDENTITY:-$default_identity}"

# Notarization rejects signatures without a secure timestamp. Local signing does not need one and is
# faster (and works offline) without it, so only Developer ID builds pay for Apple's timestamp server.
timestamp=--timestamp=none
if [[ -n ${TACK_NOTARY_PROFILE:-} || $identity == Developer\ ID* ]]; then
    timestamp=--timestamp
fi

codesign --force --options runtime "$timestamp" --entitlements "$entitlements" --sign "$identity" "$app"
codesign --verify --strict "$app"
echo "Built $app ($version build $build_number, signed with ${identity/#-/ad-hoc})"

if $install; then
    # SIGTERM instead of `osascript quit`, which blocks on an Automation consent prompt when run from a terminal.
    if pkill -x Tack; then
        for _ in $(seq 1 50); do
            pgrep -x Tack >/dev/null || break
            sleep 0.1
        done
        pkill -9 -x Tack || true
    fi
    rm -rf /Applications/Tack.app
    cp -R "$app" /Applications/Tack.app
    echo "Installed /Applications/Tack.app"
fi
