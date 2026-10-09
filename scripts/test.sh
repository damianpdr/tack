#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
# With full Xcode selected, the stock toolchain finds swift-testing on its own.
case "$(xcode-select -p)" in
    *CommandLineTools*) ;;
    *) exec swift test --scratch-path .build-core "$@" ;;
esac
FRAMEWORKS=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
exec swift test --scratch-path .build-core \
    -Xswiftc -F -Xswiftc "$FRAMEWORKS" \
    -Xlinker -F -Xlinker "$FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
    -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib \
    "$@"
