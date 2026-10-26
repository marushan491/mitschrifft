#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Mitschrift"
BUNDLE_ID="com.anpalahan.mitschrift"
INSTALL_DIR="$HOME/Applications"
APP="$INSTALL_DIR/$APP_NAME.app"
IDENTITY="${MITSCHRIFT_SIGN_IDENTITY:-Apple Development: Marushan Anpalahan (27B44ZZP5X)}"

PARTIAL="$HOME/Library/Application Support/mitschrift/partial"
if [[ "${MITSCHRIFT_FORCE:-0}" != "1" ]] && find "$PARTIAL" -name '*.jsonl' -mtime -2m 2>/dev/null | grep -q .; then
    echo "Es laeuft gerade eine Aufnahme. Nach dem Termin erneut starten oder MITSCHRIFT_FORCE=1 ./build.sh"
    exit 1
fi

echo "==> Kompilieren"
swift build -c release 2>&1 | grep -vE "^ *[0-9]+ \||warning:|note:|^ *\||^\[#|^$" || true
BIN=".build/release/mitschrift"
test -x "$BIN"

echo "==> Bundle bauen"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/mitschrift"

echo "==> Symbole erzeugen"
ICONS=$(mktemp -d)
"$BIN" icons "$ICONS" >/dev/null
SET="$ICONS/AppIcon.iconset"
mkdir -p "$SET"
cp "$ICONS/icon_16.png"   "$SET/icon_16x16.png"
cp "$ICONS/icon_32.png"   "$SET/icon_16x16@2x.png"
cp "$ICONS/icon_32.png"   "$SET/icon_32x32.png"
cp "$ICONS/icon_64.png"   "$SET/icon_32x32@2x.png"
cp "$ICONS/icon_128.png"  "$SET/icon_128x128.png"
cp "$ICONS/icon_256.png"  "$SET/icon_128x128@2x.png"
cp "$ICONS/icon_256.png"  "$SET/icon_256x256.png"
cp "$ICONS/icon_512.png"  "$SET/icon_256x256@2x.png"
cp "$ICONS/icon_512.png"  "$SET/icon_512x512.png"
cp "$ICONS/icon_1024.png" "$SET/icon_512x512@2x.png"
iconutil -c icns "$SET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONS"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>mitschrift</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Mitschrift transkribiert deine Gespraeche lokal auf diesem Mac.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Mitschrift wandelt die Aufnahme lokal in Text um.</string>
</dict>
</plist>
PLIST

echo "==> Signieren"
codesign --force --sign "$IDENTITY" \
    --options runtime \
    --entitlements mitschrift.entitlements \
    --timestamp=none \
    "$APP" 2>&1 | sed 's/^/    /'
codesign -dv "$APP" 2>&1 | grep -E "Identifier|TeamIdentifier|Authority=Apple Development" | sed 's/^/    /'

echo "==> Bei Spotlight und LaunchServices anmelden"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" 2>/dev/null || true
mdimport "$APP" 2>/dev/null || true

mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/mitschrift" <<SHIM
#!/bin/bash
exec "$APP/Contents/MacOS/mitschrift" "\$@"
SHIM
chmod +x "$HOME/.local/bin/mitschrift"

echo "==> Anmeldedienst starten"
launchctl bootout "gui/$(id -u)/$BUNDLE_ID" 2>/dev/null || true
pkill -x mitschrift 2>/dev/null || true
sleep 1
"$APP/Contents/MacOS/mitschrift" install
launchctl print "gui/$(id -u)/$BUNDLE_ID" | grep -E "state =|pid =" | sed 's/^/    /'

echo "==> Fertig: $APP"
