#!/bin/bash
# Builds build/Tack-<version>.dmg: Tack.app next to an /Applications symlink.
# Set TACK_NOTARY_PROFILE (an `xcrun notarytool store-credentials` profile) to also notarize and
# staple; that needs a Developer ID in TACK_SIGN_IDENTITY.
set -euo pipefail

cd "$(dirname "$0")/.."

[ $# -eq 0 ] || { echo "usage: $0" >&2; exit 64; }

version="$(tr -d '[:space:]' < VERSION)"
dmg="build/Tack-$version.dmg"
staging=build/dmg

notary="${TACK_NOTARY_PROFILE:-}"
if [[ -n $notary && ${TACK_SIGN_IDENTITY:-} != Developer\ ID* ]]; then
    echo "TACK_NOTARY_PROFILE is set, but Apple only notarizes Developer ID builds." >&2
    echo "Run again with TACK_SIGN_IDENTITY=\"Developer ID Application: … (TEAMID)\"." >&2
    exit 64
fi

scripts/build-app.sh

rm -rf "$staging" "$dmg"
mkdir -p "$staging"
cp -R build/Tack.app "$staging/Tack.app"
ln -s /Applications "$staging/Applications"
hdiutil create -quiet -srcfolder "$staging" -volname Tack -fs HFS+ -format UDZO "$dmg"
rm -rf "$staging"

# A signed disk image lets Gatekeeper check the download itself, not only the app inside it.
if [[ ${TACK_SIGN_IDENTITY:-} == Developer\ ID* ]]; then
    codesign --sign "$TACK_SIGN_IDENTITY" --timestamp "$dmg"
fi

if [ -n "$notary" ]; then
    xcrun notarytool submit "$dmg" --keychain-profile "$notary" --wait
    xcrun stapler staple "$dmg"
    echo "Notarized and stapled $dmg"
fi

echo "Built $dmg ($(du -h "$dmg" | cut -f1))"
