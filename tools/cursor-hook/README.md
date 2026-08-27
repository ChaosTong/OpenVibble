# Cursor → OpenVibble Desktop bridge

Forwards [Cursor IDE agent hooks](https://cursor.com/docs/hooks) to **OpenVibble Desktop**'s localhost HTTP bridge. Phone shows **session status** (busy / done / activity log) — not blocking approval.

## Prerequisites

- macOS with Node.js and `jq` (`brew install node jq`)
- **OpenVibble Desktop** running (writes `~/.claude/openvibble.port`)
- iPhone/Android with **OpenVibble** app connected via Bluetooth

## Install

```bash
# Default: status-only — phone sees running/done/log lines, never blocks Cursor
tools/cursor-hook/install.sh

# Bridge: OpenVibble Desktop **or** Node daemon (not both)
tools/node-bridge/install.sh

# Optional: blocking phone approve/deny (MCP + file tools) — requires Desktop
tools/cursor-hook/install.sh permission
```

Registers hooks in `~/.cursor/hooks.json`. Idempotent — safe to re-run.

## Uninstall

```bash
tools/cursor-hook/install.sh uninstall
```

## What the phone shows (status mode)

| Cursor event | Phone effect |
| --- | --- |
| `beforeSubmitPrompt` | Busy + project name (new turn started) |
| `preToolUse` / reads / edits / MCP | Activity log line (e.g. `write README.md`) |
| `stop` | Celebrate — turn finished |
| `sessionStart` / `sessionEnd` | Session count |

**Conversation title:** the first `beforeSubmitPrompt` text is cached per `conversation_id` (max 48 chars) and attached to later events as `conversation_title`. Phone log lines look like `UserPromptSubmit [Birkin] 修复登录问题…`.

**Does not block Cursor.** Approval stays in Cursor UI only.

**Limitation:** Cursor's internal "Pending approval" (Run/Skip) is not exposed to hooks before you click — the phone shows *running/busy* and tool lines, not "waiting for your click in Cursor".

## Permission mode (optional)

```bash
tools/cursor-hook/install.sh permission
```

| Cursor hook | Phone effect |
| --- | --- |
| `beforeMCPExecution` / gated `preToolUse` | Blocking approve/deny on phone (≤32s) |

Set `OVD_CURSOR_GATE_WRITES=0` to skip file-tool gates. See `cursor_hook_permission.js`.

## Manual bridge test

Any local client can POST to OpenVibble Desktop (not only Cursor hooks). Requires Desktop running and phone connected over BLE.

```bash
curl -s --max-time 30 \
  -H "X-OVD-Token: $(jq -r .token ~/.claude/openvibble.port)" \
  http://127.0.0.1:$(jq -r .port ~/.claude/openvibble.port)/pretooluse \
  -d '{"session_id":"demo","cwd":"/path/to/project","tool_name":"Bash","tool_input":{"command":"ls"}}'
```

Returns `204 No Content` on success; phone shows a busy flash and a log line.

Blocking approval uses `POST /permission-request` — only in **permission** install mode.

## Debug

```bash
export CURSOR_HOOK_DEBUG=1
tail -f /tmp/openvibble-cursor-hook-debug.jsonl
```

## Environment

| Variable | Default | Purpose |
| --- | --- | --- |
| `OVD_PORT_FILE` | `~/.claude/openvibble.port` | Bridge port + token |
| `OVD_CURSOR_OBSERVE` | `1` in status install | Set `0` to disable `cursor_hook.js` |
| `OVD_CURSOR_HOOK_TIMEOUT_MS` | `500` | Async hook HTTP timeout |
| `OVD_CURSOR_PERMISSION_TIMEOUT_MS` | `30000` | Permission mode wait |
| `OVD_CURSOR_GATE_WRITES` | `1` | Permission mode: set `0` to skip file-tool gate |
| `OVD_CURSOR_PERMISSION_ECHO` | `1` | Permission mode: set `0` to disable |
