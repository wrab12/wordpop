#!/bin/bash
# Builds 划词查词 (WordPop) with nothing but the Xcode Command Line Tools.
#   ./build.sh            build build/WordPop.app (universal: Apple silicon + Intel)
#   ./build.sh install    build, copy to ~/Applications and (re)start it
#   ./build.sh test       build and run the tests in tests/
#   ./build.sh release    build and package dist/WordPop-<version>.dmg and .zip
set -euo pipefail
cd "$(dirname "$0")"

APP=build/WordPop.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" mac/Info.plist)
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" mac/Info.plist)
CFLAGS=(-fobjc-arc -fmodules -O2 -Wall -mmacosx-version-min=13.0 -arch arm64 -arch x86_64)

build() {
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  clang "${CFLAGS[@]}" \
    -framework Cocoa -framework Carbon -framework CoreServices -framework ApplicationServices \
    -framework AVFoundation -framework ServiceManagement \
    mac/main.m -o "$APP/Contents/MacOS/WordPop"
  # The OCR helper: holds Vision's text model, started on demand, quits when idle.
  clang "${CFLAGS[@]}" \
    -framework Foundation -framework CoreGraphics -framework CoreServices -framework ImageIO \
    -framework Vision -framework ScreenCaptureKit -framework UniformTypeIdentifiers \
    mac/ocr.m -o "$APP/Contents/MacOS/WordPopOCR"
  cp mac/Info.plist "$APP/Contents/Info.plist"
  cp mac/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
  codesign --force --sign - --identifier "$BUNDLE_ID.ocr" "$APP/Contents/MacOS/WordPopOCR"
  # Pin the designated requirement to the bundle ID, so the Accessibility and Screen
  # Recording permissions survive updates (an ad-hoc signature would otherwise tie
  # them to this exact build).
  codesign --force --sign - --requirements "=designated => identifier \"$BUNDLE_ID\"" "$APP"
  echo "Built $APP $VERSION"
}

case "${1:-build}" in
  build)
    build
    ;;
  install)
    build
    pkill -x WordPop 2>/dev/null && sleep 0.5 || true
    mkdir -p ~/Applications/WordPop.app
    ditto "$APP" ~/Applications/WordPop.app
    open ~/Applications/WordPop.app
    echo "Installed ~/Applications/WordPop.app"
    ;;
  test)
    build
    tests/run.sh
    ;;
  release)
    build
    rm -rf build/dmg dist
    mkdir -p build/dmg dist
    ditto "$APP" build/dmg/WordPop.app
    ln -s /Applications build/dmg/Applications
    hdiutil create -quiet -volname "划词查词 $VERSION" -srcfolder build/dmg -ov -format UDZO "dist/WordPop-$VERSION.dmg"
    ditto -c -k --keepParent "$APP" "dist/WordPop-$VERSION.zip"
    (cd dist && shasum -a 256 "WordPop-$VERSION.dmg" "WordPop-$VERSION.zip" > SHA256SUMS.txt)
    ls -lh dist
    ;;
  *)
    echo "usage: $0 [build|install|test|release]" >&2
    exit 2
    ;;
esac
