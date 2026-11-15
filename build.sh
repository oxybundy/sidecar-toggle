#!/bin/bash
# Builds "Sidecar Toggle.app" (Universal: Apple Silicon + Intel).
#   ./build.sh        → build/Sidecar Toggle.app
#   ./build.sh dmg    → also build/SidecarToggle.dmg (drag-to-Applications installer)
#   ./build.sh install → also copies the app into /Applications
set -euo pipefail
cd "$(dirname "$0")"

NAME="Sidecar Toggle"
OUT="build"
APP="$OUT/$NAME.app"

rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for arch in arm64 x86_64; do
  echo "→ compiling $arch"
  swiftc -O -swift-version 5 -target "$arch-apple-macos13.0" Sources/main.swift -o "$OUT/SidecarToggle-$arch"
done
lipo -create -output "$APP/Contents/MacOS/SidecarToggle" "$OUT"/SidecarToggle-arm64 "$OUT"/SidecarToggle-x86_64
rm "$OUT"/SidecarToggle-arm64 "$OUT"/SidecarToggle-x86_64

cp Resources/Info.plist "$APP/Contents/Info.plist"
iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature by default; set SIGN_IDENTITY="Developer ID Application: …" to sign for real.
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"
echo "✓ $APP"

case "${1:-}" in
  dmg)
    DMG="$OUT/SidecarToggle.dmg"
    STAGE="$OUT/dmg"
    RW="$OUT/rw.dmg"
    mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname "$NAME" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RW" >/dev/null
    rm -rf "$STAGE"

    # Lay out the window: app on the left, Applications on the right. Best effort:
    # if Finder scripting isn't allowed (e.g. headless CI), the DMG still works.
    MOUNT=$(hdiutil attach "$RW" -readwrite -noverify -noautoopen | grep -o '/Volumes/.*$' | tail -1)
    osascript <<EOS || echo "  (skipped window layout)"
tell application "Finder"
  tell disk "$(basename "$MOUNT")"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 740, 460}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 13
    set position of item "$NAME.app" of container window to {140, 150}
    set position of item "Applications" of container window to {400, 150}
    update without registering applications
    delay 1
    close
  end tell
end tell
EOS
    sync
    hdiutil detach "$MOUNT" -quiet || hdiutil detach "$MOUNT" -force -quiet
    hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG" >/dev/null
    rm -f "$RW"
    codesign --force --sign "${SIGN_IDENTITY:--}" "$DMG"
    echo "✓ $DMG"
    ;;
  install)
    pkill -x SidecarToggle 2>/dev/null || true
    rm -rf "/Applications/$NAME.app"
    cp -R "$APP" /Applications/
    open "/Applications/$NAME.app"
    echo "✓ installed to /Applications"
    ;;
esac
