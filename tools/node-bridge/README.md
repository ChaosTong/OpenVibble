# OpenVibble Node Bridge

Lightweight **Node daemon** replacing **OpenVibble Desktop** for Cursor / Claude hook → phone status relay.

```
Cursor hooks → cursor_hook.js → http://127.0.0.1:PORT → this daemon → BLE → iPhone OpenVibble
```

Same port file as Desktop: `~/.claude/openvibble.port`

## Features (status mode)

| Endpoint | Effect |
|---|---|
| `GET /health` | Liveness (+ `ble: true/false`) |
| `POST /prompt` | Busy + log line + title |
| `POST /pretooluse` | Tool activity log |
| `POST /stop` | Celebrate (`completed: true`) + clear running |
| `POST /session-*`, `/subagent-*`, `/notification` | Same as Desktop |

`POST /permission-request` returns `ask` immediately (non-blocking). Use Desktop if you need phone approve/deny.

## Install

```bash
# 1. Stop OpenVibble Desktop (only one bridge should own the port file)
# 2. Install daemon
tools/node-bridge/install.sh

# 3. Cursor hooks (status mode)
tools/cursor-hook/install.sh status
```

Manual run:

```bash
cd tools/node-bridge && npm install && node index.js
# Web UI: http://127.0.0.1:52847/  (default port; token still in ~/.claude/openvibble.port)
```

## Web UI

Open **`http://127.0.0.1:<port>/`** in a browser (port from daemon log or `openvibble.port`).

| 功能 | 说明 |
|---|---|
| 会话统计 | total / running / waiting |
| Hook 日志 | 最近 Cursor hook 行 |
| 预设 Heartbeat | idle / busy / attention / done 等推送到手机 |
| BLE 命令 | status、time sync、name、owner、unpair |
| 模拟 Hook | 不经过 Cursor 测试 prompt / tool / stop |
| Raw JSON | 任意 NDJSON 行发到手机 |
| 活动日志 | daemon 运行日志，可清空 |

API（需 `X-OVD-Token`）：`GET /api/status`，`POST /api/ble/preset`，`POST /api/ble/command`，`POST /api/test/hook`。

## Requirements

- macOS, Node 18+
- **@abandonware/noble** for BLE (installed via `npm install`)
- iPhone **OpenVibble** app open + Bluetooth (advertises name prefix `Claude…`)
- **Bluetooth permission** for the process running Node:
  - **Recommended (macOS):** build `mac-ble-helper.app` (`mac-ble-helper/build.sh` or `install.sh`) and grant **OpenVibble BLE Helper** in **System Settings → Privacy & Security → Bluetooth**
  - Manual `node index.js` in Terminal → enable **Terminal** (or **Cursor** if using integrated terminal)
  - launchd + noble fallback → enable **node** in the same panel
- Repeated `SIGABRT` from noble → run `mac-ble-helper/build.sh`; the Swift helper has a proper Bluetooth usage description

## Env

| Variable | Default | Purpose |
|---|---|---|
| `OVD_PORT_FILE` | `~/.claude/openvibble.port` | Hook token + port |
| `OVD_BLE_NAME_PREFIX` | `Claude` | Scan filter for phone |
| `OVD_DAEMON_BLE` | `1` | Set `0` for HTTP-only (no phone push) |
| `OVD_DAEMON_HOST` | `127.0.0.1` | Bind address |
| `OVD_DAEMON_PORT` | `52847` | Fixed HTTP port (Web UI + hooks) |

## vs Desktop

| | Node daemon | OpenVibble Desktop |
|---|---|---|
| HTTP hook bridge | ✅ | ✅ |
| BLE → phone | ✅ (noble) | ✅ (CoreBluetooth) |
| UI / test panel | ❌ | ✅ |
| Phone permission gate | ❌ (ask only) | ✅ |
| Claude Code hook register | ❌ | ✅ |
| Character install / GIF | ❌ | ✅ |

## Logs

```bash
tail -f ~/Library/Logs/openvibble-node-bridge.log
```

## Uninstall

```bash
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.openvibble.node-bridge.plist
rm ~/Library/LaunchAgents/com.openvibble.node-bridge.plist
```
