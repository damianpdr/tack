#!/bin/bash
# Builds the DMG and prints the `gh release create` command for it. `--publish` runs it.
set -euo pipefail

cd "$(dirname "$0")/.."

publish=false
for arg in "$@"; do
    case "$arg" in
        --publish) publish=true ;;
        *) echo "usage: $0 [--publish]" >&2; exit 64 ;;
    esac
done

version="$(tr -d '[:space:]' < VERSION)"
tag="v$version"
dmg="build/Tack-$version.dmg"

if $publish; then
    if [ -n "$(git status --porcelain)" ]; then
        echo "working tree is dirty; commit or stash before publishing $tag" >&2
        exit 1
    fi
    if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
        echo "tag $tag already exists; bump VERSION first" >&2
        exit 1
    fi
fi

scripts/make-dmg.sh

if $publish; then
    gh release create "$tag" "$dmg" --title "Tack $version" --generate-notes
else
    echo "Not published. Run scripts/release.sh --publish, or:"
    echo "  gh release create $tag $dmg --title \"Tack $version\" --generate-notes"
fi
