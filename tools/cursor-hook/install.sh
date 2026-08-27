#!/usr/bin/env bash
# OpenVibble Cursor hook installer (macOS)
#
# Registers Cursor agent hooks that forward events to OpenVibble Desktop's
# localhost HTTP bridge (~/.claude/openvibble.port), which relays them to a
# connected iOS/Android OpenVibble app over BLE.
#
# Prereqs: Node.js, jq, OpenVibble Desktop running with a paired phone.
#
# Idempotent — re-run any time. Merges into ~/.cursor/hooks.json without
# touching other tools' entries.
#
# Uninstall: ./install.sh uninstall

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_JSON="${HOME}/.cursor/hooks.json"
MARKER="OVD-CURSOR-v1"

# status (default): session visibility only — never blocks Cursor.
HOOK_EVENTS_ASYNC=()

HOOK_EVENTS_ASYNC_STATUS=(
  sessionStart
  beforeSubmitPrompt
  beforeReadFile
  beforeMCPExecution
  afterShellExecution
  afterMCPExecution
  afterFileEdit
  stop
  sessionEnd
  subagentStart
  subagentStop
)

HOOK_EVENTS_ASYNC_OBSERVE=("${HOOK_EVENTS_ASYNC_STATUS[@]}")

HOOK_EVENTS_SYNC=()

# preToolUse observe: log tool activity, no phone approval.
PRETOOLUSE_MATCHER='.*'

INSTALL_MODE="${1:-status}"

require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "✗ jq not found. Install with: brew install jq"
    exit 1
  fi
}

detect_node() {
  if command -v node >/dev/null 2>&1; then
    command -v node
  elif [[ -x /opt/homebrew/bin/node ]]; then
    echo "/opt/homebrew/bin/node"
  elif [[ -x /usr/local/bin/node ]]; then
    echo "/usr/local/bin/node"
  else
    echo "✗ node not found. Install Node.js (brew install node) and re-run." >&2
    exit 1
  fi
}

backup_hooks_json() {
  if [[ -f "${HOOKS_JSON}" ]]; then
    local bak="${HOOKS_JSON}.bak.$(date +%s)"
    cp "${HOOKS_JSON}" "${bak}"
    echo "→ backed up ${HOOKS_JSON} → ${bak}"
  fi
}

strip_ovd_cursor_hooks() {
  local tmp hook_basename
  for hook_basename in cursor_hook.js cursor_hook_permission.js; do
    tmp="$(mktemp)"
    jq --arg p "${hook_basename}" '
      .hooks //= {}
      | .hooks |= with_entries(
          .value |= map(select((.command // "") | contains($p) | not))
        )
    ' "${HOOKS_JSON}" > "${tmp}" && mv "${tmp}" "${HOOKS_JSON}"
  done
  tmp="$(mktemp)"
  jq '.hooks //= {} | .hooks |= with_entries(select(.value | length > 0))' \
    "${HOOKS_JSON}" > "${tmp}" && mv "${tmp}" "${HOOKS_JSON}"
}

uninstall() {
  require_jq
  if [[ -f "${HOOKS_JSON}" ]]; then
    backup_hooks_json
    echo "→ stripping OpenVibble Cursor hook entries from ${HOOKS_JSON}"
    strip_ovd_cursor_hooks
  fi
  echo "✓ uninstalled OpenVibble Cursor hooks"
}

if [[ "${INSTALL_MODE}" == "uninstall" ]]; then
  uninstall
  exit 0
fi

if [[ "${INSTALL_MODE}" == "status" ]]; then
  HOOK_EVENTS_ASYNC=("${HOOK_EVENTS_ASYNC_STATUS[@]}")
  HOOK_EVENTS_SYNC=()
elif [[ "${INSTALL_MODE}" == "observe" ]]; then
  HOOK_EVENTS_ASYNC=("${HOOK_EVENTS_ASYNC_OBSERVE[@]}")
  HOOK_EVENTS_SYNC=()
elif [[ "${INSTALL_MODE}" == "permission" ]]; then
  HOOK_EVENTS_ASYNC=()
  HOOK_EVENTS_SYNC=(beforeMCPExecution)
  PRETOOLUSE_MATCHER='CallDynamicTool|GetDynamicTool|FetchMcpResource|MCP|Task|Write|Edit|StrReplace|Delete'
else
  echo "Usage: $0 [status|observe|permission|uninstall]" >&2
  echo "  status (default) — session/tool visibility on phone, no blocking" >&2
  echo "  observe          — same as status (alias)" >&2
  echo "  permission       — blocking phone approve/deny for MCP + file tools" >&2
  exit 1
fi

require_jq
NODE_BIN="$(detect_node)"
echo "→ using node: ${NODE_BIN}"

mkdir -p "$(dirname "${HOOKS_JSON}")"
[[ -f "${HOOKS_JSON}" ]] || echo '{ "version": 1, "hooks": {} }' > "${HOOKS_JSON}"

chmod +x "${HERE}/cursor_hook.js" "${HERE}/cursor_hook_permission.js" 2>/dev/null || true

backup_hooks_json
echo "→ stripping any prior OpenVibble Cursor hook entries"
strip_ovd_cursor_hooks

tmp="$(mktemp)"
jq '.version //= 1' "${HOOKS_JSON}" > "${tmp}" && mv "${tmp}" "${HOOKS_JSON}"

HOOK_PATH_ASYNC="${HERE}/cursor_hook.js"
HOOK_PATH_SYNC="${HERE}/cursor_hook_permission.js"
HOOK_CMD_ASYNC="OVD_CURSOR_OBSERVE=1 ${NODE_BIN} ${HOOK_PATH_ASYNC} # ${MARKER}"
HOOK_CMD_SYNC="${NODE_BIN} ${HOOK_PATH_SYNC} # ${MARKER}"
SYNC_HOOK_TIMEOUT_S=32

add_hook() {
  local ev="$1" cmd="$2" timeout="$3" matcher="${4:-}"
  local tmp
  tmp="$(mktemp)"
  jq --arg ev "${ev}" --arg cmd "${cmd}" --arg timeout "${timeout}" --arg matcher "${matcher}" '
    .hooks //= {}
    | .hooks[$ev] //= []
    | if (.hooks[$ev] | map(.command // "") | any(. == $cmd))
      then .
      else
        .hooks[$ev] += [
          if $timeout == "" and $matcher == ""
          then {"command": $cmd}
          elif $timeout == "" and $matcher != ""
          then {"command": $cmd, "matcher": $matcher}
          elif $matcher == ""
          then {"command": $cmd, "timeout": ($timeout | tonumber)}
          else {"command": $cmd, "timeout": ($timeout | tonumber), "matcher": $matcher}
          end
        ]
      end
  ' "${HOOKS_JSON}" > "${tmp}" && mv "${tmp}" "${HOOKS_JSON}"
}

if [[ "${INSTALL_MODE}" == "status" || "${INSTALL_MODE}" == "observe" ]]; then
  for ev in "${HOOK_EVENTS_ASYNC[@]}"; do
    add_hook "${ev}" "${HOOK_CMD_ASYNC}" ""
  done
  add_hook "preToolUse" "${HOOK_CMD_ASYNC}" "" "${PRETOOLUSE_MATCHER}"
elif [[ "${INSTALL_MODE}" == "permission" ]]; then
  for ev in "${HOOK_EVENTS_SYNC[@]}"; do
    add_hook "${ev}" "${HOOK_CMD_SYNC}" "${SYNC_HOOK_TIMEOUT_S}" ""
  done
  add_hook "preToolUse" "${HOOK_CMD_SYNC}" "${SYNC_HOOK_TIMEOUT_S}" "${PRETOOLUSE_MATCHER}"
fi

if [[ "${INSTALL_MODE}" == "status" || "${INSTALL_MODE}" == "observe" ]]; then
  echo "→ wired status hooks: ${HOOK_EVENTS_ASYNC[*]} preToolUse(matcher=${PRETOOLUSE_MATCHER})"
  echo "→ blocking permission hooks: none"
elif [[ "${INSTALL_MODE}" == "permission" ]]; then
  echo "→ wired permission hooks: ${HOOK_EVENTS_SYNC[*]} preToolUse(matcher=${PRETOOLUSE_MATCHER}) (timeout=${SYNC_HOOK_TIMEOUT_S}s)"
fi

cat <<EOF

✓ OpenVibble Cursor hooks installed (${INSTALL_MODE} mode).

Before using Cursor:
  1. Launch OpenVibble Desktop and connect your iPhone (OpenVibble app open).
  2. Confirm bridge is up: curl -s http://127.0.0.1:\$(jq -r .port ~/.claude/openvibble.port)/health

Debug: CURSOR_HOOK_DEBUG=1 in your shell, then tail -f /tmp/openvibble-cursor-hook-debug.jsonl

Uninstall: ${HERE}/install.sh uninstall
EOF
