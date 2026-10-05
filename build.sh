#!/bin/bash
# Baut "TU VPN.app" (Universal: Apple Silicon + Intel) — braucht nur die Xcode Command Line Tools.
#
#   ./build.sh             App nach build/ bauen
#   ./build.sh test        Tests (Swift-Logik + Shell-Helper)
#   ./build.sh --install   bauen, nach /Applications kopieren und starten (eine laufende VPN-Verbindung bleibt)
#   ./build.sh --release   bauen + dist/TUvpn-macOS.zip und dist/SHA256SUMS (so baut auch die CI)
set -euo pipefail
cd "$(dirname "$0")"

readonly APP_NAME="TU VPN"
readonly APP_DIR="build/$APP_NAME.app"
readonly MIN_MACOS="13.0"
readonly ZIP_NAME="TUvpn-macOS.zip"

run_tests() {
  mkdir -p build
  swiftc -swift-version 5 Sources/Core/*.swift Tests/main.swift -o build/core-tests
  ./build/core-tests
  bash Tests/helper_tests.sh
  local script
  for script in install.sh uninstall.sh build.sh Helper/tuvpn-helper Helper/tuvpn-setup.sh Tests/helper_tests.sh; do
    bash -n "$script"
  done
  echo "✅ alle Tests grün"
}

build_app() {
  rm -rf build
  mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
  for arch in arm64 x86_64; do
    swiftc -parse-as-library -swift-version 5 -O \
      -target "$arch-apple-macos$MIN_MACOS" \
      Sources/Core/*.swift Sources/App/*.swift -o "build/TUvpn-$arch"
  done
  lipo -create build/TUvpn-arm64 build/TUvpn-x86_64 -output "$APP_DIR/Contents/MacOS/TUvpn"
  rm build/TUvpn-arm64 build/TUvpn-x86_64

  cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
  cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
  cp Helper/tuvpn-helper Helper/tuvpn-setup.sh "$APP_DIR/Contents/Resources/"
  chmod 755 "$APP_DIR/Contents/Resources/tuvpn-helper" "$APP_DIR/Contents/Resources/tuvpn-setup.sh"

  # Ad-hoc-Signatur (kein Apple-Developer-Zertifikat, daher nicht notarisiert)
  codesign --force --sign - --identifier io.github.hannokuegler.tuvpn "$APP_DIR"
  codesign --verify --strict "$APP_DIR"
  echo "✅ $APP_DIR gebaut ($(lipo -archs "$APP_DIR/Contents/MacOS/TUvpn"))"
}

case "${1:-}" in
  test)
    run_tests
    ;;
  --release)
    run_tests
    build_app
    rm -rf dist
    mkdir -p dist
    ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "dist/$ZIP_NAME"
    (cd dist && shasum -a 256 "$ZIP_NAME" >SHA256SUMS)
    cat dist/SHA256SUMS
    ;;
  --install)
    build_app
    pkill -x TUvpn 2>/dev/null || true
    rm -rf "/Applications/$APP_NAME.app"
    ditto "$APP_DIR" "/Applications/$APP_NAME.app"
    open "/Applications/$APP_NAME.app"
    echo "✅ installiert und gestartet: /Applications/$APP_NAME.app"
    ;;
  "")
    build_app
    ;;
  *)
    echo "Aufruf: ./build.sh [test | --install | --release]" >&2
    exit 64
    ;;
esac
