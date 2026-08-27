#!/usr/bin/env bash
# Install OpenVibble Node bridge daemon (macOS launchd user agent)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="com.openvibble.node-bridge"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
NODE_BIN="$(command -v node)"

if [[ -z "${NODE_BIN}" ]]; then
  echo "✗ node not found (brew install node)" >&2
  exit 1
fi

echo "→ npm install (optional @abandonware/noble for BLE fallback)"
(cd "${HERE}" && npm install --omit=dev 2>/dev/null || npm install --omit=dev)

if [[ "$(uname -s)" == "Darwin" ]]; then
  echo "→ build mac-ble-helper.app (recommended on macOS)"
  bash "${HERE}/mac-ble-helper/build.sh"
fi

mkdir -p "${HOME}/Library/LaunchAgents"

cat > "${PLIST}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${NODE_BIN}</string>
    <string>${HERE}/index.js</string>
  </array>
  <key>WorkingDirectory</key>
  <string>${HERE}</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${HOME}/Library/Logs/openvibble-node-bridge.log</string>
  <key>StandardErrorPath</key>
  <string>${HOME}/Library/Logs/openvibble-node-bridge.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>OVD_DAEMON_BLE</key>
    <string>1</string>
    <key>OVD_DAEMON_PORT</key>
    <string>52847</string>
  </dict>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)" "${PLIST}" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "${PLIST}"
launchctl enable "gui/$(id -u)/${LABEL}" 2>/dev/null || true

echo "✓ Node bridge installed"
echo "  log: ~/Library/Logs/openvibble-node-bridge.log"
echo "  port: ~/.claude/openvibble.port"
echo ""
echo "Stop Desktop app first if both write the same port file."
echo "Uninstall: launchctl bootout gui/\$(id -u) ${PLIST} && rm ${PLIST}"
