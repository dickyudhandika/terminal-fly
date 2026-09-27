#!/usr/bin/env bash
# Terminal Fly build script.
#
# Why not XcodeGen + xcodebuild? This machine has only Command Line Tools
# (no Xcode.app), so `xcodebuild` cannot run. SwiftPM is also unusable: the
# CLT-shipped libPackageDescription.dylib is missing symbols, so every
# Package.swift manifest fails to link ("Undefined symbols:
# PackageDescription.Package.__allocating_init"). We compile SwiftTerm and the
# app sources directly with swiftc instead. Same sources, same result.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIG="${1:-debug}"
APP_NAME="TerminalFly"
BUILD_DIR="$ROOT/build"
GEN_DIR="$BUILD_DIR/generated"
OBJ_DIR="$BUILD_DIR/$CONFIG"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
SWIFTTERM_DIR="$ROOT/vendor/SwiftTerm"

case "$CONFIG" in
  debug)   OPT=(-Onone -g -DDEBUG) ;;
  release) OPT=(-O -whole-module-optimization) ;;
  *) echo "usage: $0 [debug|release]" >&2; exit 2 ;;
esac

SDK="$(xcrun --show-sdk-path --sdk macosx)"
TARGET="arm64-apple-macosx14.0"
# -swift-version 5, not 6: Swift 6 language mode needs a newer toolchain than
# some CI runners ship (GitHub's macos-14 image supports only 4 / 4.2 / 5 and
# hard-errors on 6). The app and SwiftTerm both compile cleanly in Swift 5 mode,
# and the strict-concurrency annotations in the sources stay meaningful as
# warnings. Bump this only when the oldest supported toolchain accepts it.
COMMON=(-sdk "$SDK" -target "$TARGET" -swift-version 5 -I "$OBJ_DIR")

mkdir -p "$GEN_DIR" "$OBJ_DIR"

# --- 1. Generate SwiftTermBuildInfo (normally an SPM build plugin; we run the
#        generator directly).
#
#        The generator's argument contract changed upstream: v1.20.0 takes
#        (repositoryPath, outputFile), while later revisions add a third arg for
#        a terminfo file. Try the newer 3-arg form first and fall back, so this
#        works across a range of pins rather than only the one we happen to use.
GEN_SWIFT="$GEN_DIR/SwiftTermBuildInfo.swift"
TERMINFO_SWIFT="$GEN_DIR/SwiftTermTerminfo.swift"

if [ ! -f "$GEN_SWIFT" ]; then
  echo "==> generating SwiftTerm build info"
  # -parse-as-library is required: the generator declares @main, and without it
  # the compiler treats the file as top-level code and errors with "'main'
  # attribute cannot be used in a module that contains top-level code".
  swiftc -O -parse-as-library -o "$GEN_DIR/buildinfo-gen" \
    "$SWIFTTERM_DIR"/Sources/SwiftTermBuildInfoGenerator/*.swift
  "$GEN_DIR/buildinfo-gen" "$SWIFTTERM_DIR" "$GEN_SWIFT" "$TERMINFO_SWIFT" 2>/dev/null \
    || "$GEN_DIR/buildinfo-gen" "$SWIFTTERM_DIR" "$GEN_SWIFT"
fi

# The library build would otherwise fail with a confusing "cannot find type"
# error pointing at SwiftTerm sources instead of at the real cause.
if [ ! -s "$GEN_SWIFT" ]; then
  echo "FATAL: build-info generator produced no output — check $GEN_DIR/buildinfo-gen" >&2
  exit 1
fi

# Only newer SwiftTerm revisions ship a generated terminfo source; include it
# when present instead of passing a path that may not exist.
GENERATED=("$GEN_SWIFT")
if [ -s "$TERMINFO_SWIFT" ]; then
  GENERATED+=("$TERMINFO_SWIFT")
fi

# --- 2. Build SwiftTerm into a static library + module.
if [ ! -f "$OBJ_DIR/libSwiftTerm.a" ]; then
  echo "==> compiling SwiftTerm (this takes a while, first run only)"
  find "$SWIFTTERM_DIR/Sources/SwiftTerm" -name '*.swift' >"$OBJ_DIR/swiftterm-sources.txt"
  swiftc "${COMMON[@]}" "${OPT[@]}" \
    -module-name SwiftTerm \
    -emit-module -emit-module-path "$OBJ_DIR/SwiftTerm.swiftmodule" \
    -emit-library -static -o "$OBJ_DIR/libSwiftTerm.a" \
    @"$OBJ_DIR/swiftterm-sources.txt" \
    "${GENERATED[@]}"
fi

# --- 3. Compile the app.
echo "==> compiling $APP_NAME ($CONFIG)"
find "$ROOT/Sources/$APP_NAME" -name '*.swift' >"$OBJ_DIR/app-sources.txt"
swiftc "${COMMON[@]}" "${OPT[@]}" \
  -module-name "$APP_NAME" \
  -parse-as-library \
  -o "$OBJ_DIR/$APP_NAME" \
  @"$OBJ_DIR/app-sources.txt" \
  -L "$OBJ_DIR" -lSwiftTerm \
  -framework AppKit -framework SwiftUI -framework Carbon \
  -framework Metal -framework MetalKit -framework CoreText \
  -framework CoreGraphics -framework UniformTypeIdentifiers

# --- 4. Assemble the .app bundle.
echo "==> assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$OBJ_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi
if [ -d "$ROOT/Resources/Assets.xcassets" ]; then
  cp -R "$ROOT/Resources/Assets.xcassets" "$APP_DIR/Contents/Resources/"
fi
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

# Ad-hoc signature — enough to run locally, and required for some AppKit APIs.
codesign --force --sign - --timestamp=none "$APP_DIR" >/dev/null 2>&1 \
  || echo "warning: ad-hoc codesign failed (app will still run)"

echo "==> built $APP_DIR"
