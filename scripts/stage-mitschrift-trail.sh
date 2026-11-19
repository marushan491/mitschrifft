#!/bin/bash
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."

root="$HOME/Library/Application Support/mitschrift/meeting-trail-acceptance"
mkdir -p "$root"
stage="$(mktemp -d "$root/mitschrift.XXXXXX")"
printf 'MAC_TRAIL_STAGE=%s\n' "$stage"
original="$HOME/Applications/Mitschrift.app"
mkdir -p "$stage/proof" "$stage/release"
cp mitschrift.entitlements "$stage/"
cp scripts/live_mcp.py "$stage/"

swift build -c release --jobs 2 -Xswiftc -DMEETING_TRAIL_PROOF
binary="$(swift build -c release --show-bin-path)/mitschrift"
/usr/bin/ditto "$original" "$stage/proof/Mitschrift.app"
cp "$binary" "$stage/proof/Mitschrift.app/Contents/MacOS/mitschrift"

swift build -c release --jobs 2
/usr/bin/ditto "$original" "$stage/release/Mitschrift.app"
cp "$binary" "$stage/release/Mitschrift.app/Contents/MacOS/mitschrift"
test -x "$stage/proof/Mitschrift.app/Contents/MacOS/mitschrift"
test -x "$stage/release/Mitschrift.app/Contents/MacOS/mitschrift"
