#!/bin/bash
#
# Build the Release version of PuTTY.app.
#
#   ./build-release.sh          build Release
#   ./build-release.sh clean    wipe the previous Release build first
#   ./build-release.sh zip      also make a .zip of the app for sharing
#
# Options can be combined:  ./build-release.sh clean zip
#
# The finished app always ends up in  Build/Products/Release/PuTTY.app  next
# to this script, whatever build location Xcode's preferences name.

set -euo pipefail

cd "$(dirname "$0")"
ROOT="$(pwd)"

PROJECT="PuTTY.xcodeproj"
SCHEME="PuTTY"
CONFIG="Release"
PRODUCTS="$ROOT/Build/Products"
INTERMEDIATES="$ROOT/Build/Intermediates.noindex"
APP="$PRODUCTS/$CONFIG/PuTTY.app"

DO_CLEAN=0
DO_ZIP=0
for arg in "$@"; do
    case "$arg" in
        clean) DO_CLEAN=1 ;;
        zip)   DO_ZIP=1 ;;
        -h|--help)
            sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "Unknown option: $arg (use clean and/or zip)" >&2; exit 2 ;;
    esac
done

if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "xcodebuild not found. Install Xcode, then run: sudo xcode-select -s /Applications/Xcode.app" >&2
    exit 1
fi

# Settings given here override Xcode's preferences, so the output location
# is the same on every Mac.
BUILD_ARGS=(
    -project "$PROJECT"
    -scheme "$SCHEME"
    -configuration "$CONFIG"
    -destination "generic/platform=macOS"
    ONLY_ACTIVE_ARCH=NO        # universal: Apple Silicon and Intel
    SYMROOT="$PRODUCTS"
    OBJROOT="$INTERMEDIATES"
)

# Run xcodebuild quietly, dropping Xcode's internal "[MT]" log chatter.
run_xcodebuild() {
    xcodebuild "${BUILD_ARGS[@]}" -quiet "$@" 2> >(grep -v '\[MT\]' >&2)
}

if [ "$DO_CLEAN" = 1 ]; then
    echo "==> Cleaning previous $CONFIG build"
    run_xcodebuild clean
    rm -rf "$APP"
fi

echo "==> Building PuTTY ($CONFIG)"
run_xcodebuild build

if [ ! -d "$APP" ]; then
    echo "Build finished but $APP is missing." >&2
    exit 1
fi

# Check the app's signature (ad-hoc signed: it runs on this Mac).
codesign --verify --deep --strict "$APP"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo unknown)"
ARCHS="$(lipo -archs "$APP/Contents/MacOS/PuTTY" 2>/dev/null || echo unknown)"

if [ "$DO_ZIP" = 1 ]; then
    ZIP="$PRODUCTS/$CONFIG/PuTTY-$VERSION.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "==> Zipped:  $ZIP"
fi

echo "==> Done:    $APP"
echo "    Version: $VERSION   Architectures: $ARCHS"
