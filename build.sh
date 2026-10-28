#!/bin/zsh
# Build MouseAssist.app from source, sign it, and install it to /Applications.
# Usage: ./build.sh            build + install + relaunch
#        ./build.sh --no-install
set -euo pipefail
cd "${0:A:h}"

APP=build/MouseAssist.app

# A stable signing identity keeps the Accessibility grant valid across rebuilds.
# Without one the app is signed ad hoc and has to be approved again after every build.
if [[ -z ${SIGN_ID:-} ]]; then
  if security find-identity -v -p codesigning | grep -q "Apple Development"; then
    SIGN_ID="Apple Development"
  else
    SIGN_ID="-"
  fi
fi

[[ -f Icon/AppIcon.icns ]] || swift Icon/make_icon.swift

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos13" \
  Sources/main.swift -o "$APP/Contents/MacOS/MouseAssist"
cp Info.plist "$APP/Contents/Info.plist"
cp Icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
# Hardened runtime, no entitlements.
codesign --force --options runtime --sign "$SIGN_ID" "$APP"
codesign --verify --strict "$APP"
echo "built $APP (signed with: $SIGN_ID)"

[[ ${1:-} == --no-install ]] && exit 0

pkill -x MouseAssist 2>/dev/null && sleep 1 || true
rm -rf /Applications/MouseAssist.app
ditto "$APP" /Applications/MouseAssist.app
open /Applications/MouseAssist.app
echo "installed and launched /Applications/MouseAssist.app"
