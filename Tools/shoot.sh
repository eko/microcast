#!/bin/sh
# Photographs the running app's window into a file.
#
#   Tools/shoot.sh docs/images/dashboard.png
#
# The app takes its own picture, because a capture driven from a terminal needs the *terminal* to
# hold Screen Recording permission, and MicroCast already holds it for screen streaming.
set -eu

OUT="${1:?usage: shoot.sh <out.png>}"
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"

pgrep -q MicroCast || { echo "MicroCast is not running." >&2; exit 1; }

osascript -e 'tell application "System Events" to tell process "MicroCast" to set frontmost to true' >/dev/null
sleep 0.6
# Posted from Swift rather than Python: PyObjC is not part of the system Python.
NOTIFY="${TMPDIR:-/tmp}/microcast-shoot.swift"
cat > "$NOTIFY" <<'SWIFT'
import Foundation
let path = CommandLine.arguments.dropFirst().first ?? "/tmp/microcast.png"
DistributedNotificationCenter.default().postNotificationName(
	Notification.Name("local.microcast.shoot"), object: nil,
	userInfo: ["path": path], deliverImmediately: true)
SWIFT
swift "$NOTIFY" "$OUT"

for _ in $(seq 1 40); do
	[ -s "$OUT" ] && { echo "wrote $OUT"; exit 0; }
	sleep 0.25
done
echo "no file appeared; check that MicroCast has Screen Recording permission." >&2
exit 1
