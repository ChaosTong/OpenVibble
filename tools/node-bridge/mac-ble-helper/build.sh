#!/usr/bin/env bash
# Build macOS BLE helper .app (CoreBluetooth + Info.plist — avoids noble SIGABRT)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
APP="${ROOT}/mac-ble-helper.app"
SRC="${HERE}/main.swift"
BIN="${APP}/Contents/MacOS/mac-ble-helper"

mkdir -p "${APP}/Contents/MacOS"
cp "${HERE}/Info.plist" "${APP}/Contents/Info.plist"

echo "→ swiftc mac-ble-helper (embed Info.plist for TCC when spawned by node)"
swiftc "${SRC}" -O -o "${BIN}" \
  -framework Foundation \
  -framework CoreBluetooth \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "${HERE}/Info.plist"

echo "→ codesign (bind Info.plist / Bluetooth usage description)"
codesign --force --deep --sign - "${APP}"

echo "→ clear quarantine (if any)"
xattr -cr "${APP}" 2>/dev/null || true

echo "→ probe (optional, max 3s)"
( "${BIN}" --probe & PID=$!; sleep 3; kill $PID 2>/dev/null ) 2>/dev/null || true

echo "✓ ${APP}"
echo "  If phone push fails: System Settings → Privacy → Bluetooth → OpenVibble BLE Helper"
