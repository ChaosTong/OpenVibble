# Cursor → OpenVibble Desktop bridge

Forwards [Cursor IDE agent hooks](https://cursor.com/docs/hooks) to **OpenVibble Desktop**'s localhost HTTP bridge, which relays session state to a connected iPhone/Android OpenVibble app over BLE.

This is the phone equivalent of [claude-code-buddy](https://github.com/TaoXieSZ/claude-code-buddy)'s `cursor-bridge`, but uses OpenVibble Desktop instead of M5 hardware.

## Prerequisites

- macOS with Node.js and `jq` (`brew install node jq`)
- **OpenVibble Desktop** running (writes `~/.claude/openvibble.port`)
- iPhone/Android with **OpenVibble** app connected via Bluetooth

## Install

```bash
tools/cursor-hook/install.sh
```

Registers hooks in `~/.cursor/hooks.json`. Idempotent — safe to re-run.

## Uninstall

```bash
tools/cursor-hook/install.sh uninstall
```

## Event mapping

| Cursor hook | OpenVibble endpoint | iPhone effect |
| --- | --- | --- |
| `beforeShellExecution` / `beforeMCPExecution` | `POST /permission-request` (blocking) | Permission prompt on phone |
| `beforeSubmitPrompt` | `POST /prompt` | Busy state |
| `afterAgentResponse` / `stop` | `POST /stop` | Celebrate |
| `sessionStart` / `sessionEnd` | `POST /session-start` / `session-end` | Session counts |
| Tool visibility hooks | `POST /pretooluse` | Busy flash + log line |

## Fail-open

If OpenVibble Desktop is not running or the phone is disconnected, hooks exit silently (exit 0). Cursor is never blocked except on explicit permission gates — those fall back to Cursor's native flow on timeout.

## Debug

```bash
export CURSOR_HOOK_DEBUG=1
tail -f /tmp/openvibble-cursor-hook-debug.jsonl
```

## Environment

| Variable | Default | Purpose |
| --- | --- | --- |
| `OVD_PORT_FILE` | `~/.claude/openvibble.port` | Bridge port + token |
| `OVD_CURSOR_HOOK_TIMEOUT_MS` | `500` | Async hook HTTP timeout |
| `OVD_CURSOR_PERMISSION_TIMEOUT_MS` | `30000` | Permission gate wait |
| `OVD_CURSOR_PERMISSION_ECHO` | `1` | Set `0` to disable phone approval |
