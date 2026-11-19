#!/bin/bash
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."

preview_root="$HOME/Library/Application Support/mitschrift/meeting-trail-preview"
mkdir -p "$preview_root"
preview_dir="$(mktemp -d "$preview_root/gespraechsspur.XXXXXX")"
app="$preview_dir/Gesprächsspur Vorschau.app"
mkdir -p "$app/Contents/MacOS"
xcrun swiftc -O -parse-as-library -swift-version 5 -D MEETING_TRAIL_PREVIEW \
    Sources/mitschrift/AssistantPresentationGate.swift Sources/mitschrift/MeetingTrail.swift Sources/mitschrift/MeetingTrailPilot.swift \
    scripts/meeting-trail-preview.swift \
    -o "$app/Contents/MacOS/MeetingTrailPreview"
cp scripts/live_mcp.py "$preview_dir/live_mcp.py"

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Gesprächsspur Vorschau</string>
<key>CFBundleIdentifier</key><string>com.anpalahan.mitschrift.gespraechsspur-preview</string>
<key>CFBundleExecutable</key><string>MeetingTrailPreview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --sign - "$app"
codesign --verify --strict "$app"
printf 'MAC_PREVIEW_DIR=%s\n' "$preview_dir"
