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

HOOK_EVENTS_ASYNC=(
  sessionStart
  beforeSubmitPrompt
  beforeReadFile
  afterShellExecution
  afterMCPExecution
  afterFileEdit
  afterAgentResponse
  stop
  sessionEnd
  subagentStart
  subagentStop
)

HOOK_EVENTS_SYNC=(
  beforeShellExecution
  beforeMCPExecution
)

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

if [[ "${1:-}" == "uninstall" ]]; then
  uninstall
  exit 0
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
HOOK_CMD_ASYNC="\"${NODE_BIN}\" \"${HOOK_PATH_ASYNC}\" # ${MARKER}"
HOOK_CMD_SYNC="\"${NODE_BIN}\" \"${HOOK_PATH_SYNC}\" # ${MARKER}"
SYNC_HOOK_TIMEOUT_S=32

add_hook() {
  local ev="$1" cmd="$2" timeout="$3"
  local tmp
  tmp="$(mktemp)"
  jq --arg ev "${ev}" --arg cmd "${cmd}" --arg timeout "${timeout}" '
    .hooks //= {}
    | .hooks[$ev] //= []
    | if (.hooks[$ev] | map(.command // "") | any(. == $cmd))
      then .
      else
        .hooks[$ev] += [
          if $timeout == ""
          then {"command": $cmd}
          else {"command": $cmd, "timeout": ($timeout | tonumber)}
          end
        ]
      end
  ' "${HOOKS_JSON}" > "${tmp}" && mv "${tmp}" "${HOOKS_JSON}"
}

for ev in "${HOOK_EVENTS_ASYNC[@]}"; do
  add_hook "${ev}" "${HOOK_CMD_ASYNC}" ""
done
for ev in "${HOOK_EVENTS_SYNC[@]}"; do
  add_hook "${ev}" "${HOOK_CMD_SYNC}" "${SYNC_HOOK_TIMEOUT_S}"
done

echo "→ wired async hooks: ${HOOK_EVENTS_ASYNC[*]}"
echo "→ wired sync hooks: ${HOOK_EVENTS_SYNC[*]} (timeout=${SYNC_HOOK_TIMEOUT_S}s)"

cat <<EOF

✓ OpenVibble Cursor hooks installed.

Before using Cursor:
  1. Launch OpenVibble Desktop and connect your iPhone (OpenVibble app open).
  2. Confirm bridge is up: curl -s http://127.0.0.1:\$(jq -r .port ~/.claude/openvibble.port)/health

Debug: CURSOR_HOOK_DEBUG=1 in your shell, then tail -f /tmp/openvibble-cursor-hook-debug.jsonl

Uninstall: ${HERE}/install.sh uninstall
EOF
