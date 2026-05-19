#!/usr/bin/env bash
# Hook entrypoint invoked by Claude Code / Codex.
# Reads hook JSON from stdin, builds an event-specific summary, fires a
# fire-and-forget HTTPS POST to the relay. Must NEVER exit non-zero — a
# non-zero exit from a hook can block the agent.

set -u

EVENT_KIND="${1:-done}"   # done | needs_input | error

CONFIG_DIR="${AGENT_NOTIFY_CONFIG:-$HOME/.config/agent-notify}"
TOKEN_FILE="$CONFIG_DIR/token"
RELAY_FILE="$CONFIG_DIR/relay"
RELAY="${AGENT_NOTIFY_RELAY:-}"

# Fall back to relay file so hooks work without relying on shell init order.
if [[ -z "$RELAY" && -r "$RELAY_FILE" ]]; then
  RELAY="$(tr -d '[:space:]' < "$RELAY_FILE" 2>/dev/null || true)"
fi

# Bail silently if not configured. Hooks must be invisible when off.
[[ -z "$RELAY" ]] && exit 0
[[ ! -r "$TOKEN_FILE" ]] && exit 0
command -v jq >/dev/null 2>&1 || exit 0
command -v curl >/dev/null 2>&1 || exit 0

PAYLOAD="$(cat || true)"
[[ -z "$PAYLOAD" ]] && exit 0

# Shared fields. jq prints empty string for missing keys via `// ""`.
SESSION_ID="$(printf '%s' "$PAYLOAD" | jq -r '.session_id // ""' 2>/dev/null || echo "")"
CWD="$(printf '%s' "$PAYLOAD" | jq -r '.cwd // ""' 2>/dev/null || echo "")"
HOOK_EVENT="$(printf '%s' "$PAYLOAD" | jq -r '.hook_event_name // ""' 2>/dev/null || echo "")"
[[ -z "$SESSION_ID" ]] && SESSION_ID="unknown"

# Debounce: 60s window per session
MARKER="/tmp/agent-notify-${SESSION_ID}"
if [[ -f "$MARKER" ]]; then
  NOW="$(date +%s)"
  MTIME="$(stat -c %Y "$MARKER" 2>/dev/null || stat -f %m "$MARKER" 2>/dev/null || echo 0)"
  AGE=$(( NOW - MTIME ))
  (( AGE < 60 )) && exit 0
fi
touch "$MARKER" 2>/dev/null || true

HOSTNAME_SHORT="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown)"
CWD_BASENAME="$(basename -- "$CWD" 2>/dev/null || echo "")"

# Build summary text per event type.
SUMMARY=""
case "$HOOK_EVENT" in
  Notification)
    # Claude Code Notification — free-form `message`
    SUMMARY="$(printf '%s' "$PAYLOAD" | jq -r '.message // ""' 2>/dev/null || echo "")"
    ;;
  PermissionRequest)
    # Codex PermissionRequest
    TOOL="$(printf '%s' "$PAYLOAD" | jq -r '.tool_name // ""' 2>/dev/null || echo "")"
    DETAIL="$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // .tool_input.description // ""' 2>/dev/null || echo "")"
    if [[ -n "$DETAIL" ]]; then
      SUMMARY="${TOOL}: ${DETAIL}"
    else
      SUMMARY="Permission needed${TOOL:+: $TOOL}"
    fi
    ;;
  Stop)
    LAST="$(printf '%s' "$PAYLOAD" | jq -r '.last_assistant_message // ""' 2>/dev/null || echo "")"
    if [[ -n "$LAST" ]]; then
      SUMMARY="$(printf '%s' "$LAST" | head -n 1 | cut -c1-160)"
    else
      SUMMARY="Finished${CWD_BASENAME:+ in $CWD_BASENAME}"
    fi
    ;;
  *)
    SUMMARY="$HOOK_EVENT"
    ;;
esac

# Cap summary length (APNs total payload is 4KB; leave headroom)
SUMMARY="$(printf '%s' "$SUMMARY" | cut -c1-300)"

BODY="$(jq -n \
  --arg event       "$EVENT_KIND" \
  --arg hook_event  "$HOOK_EVENT" \
  --arg session_id  "$SESSION_ID" \
  --arg cwd         "$CWD" \
  --arg cwd_base    "$CWD_BASENAME" \
  --arg machine     "$HOSTNAME_SHORT" \
  --arg summary     "$SUMMARY" \
  '{event:$event, hook_event:$hook_event, session_id:$session_id,
    cwd:$cwd, cwd_basename:$cwd_base, machine:$machine, summary:$summary}' 2>/dev/null)"

[[ -z "$BODY" ]] && exit 0

TOKEN="$(cat "$TOKEN_FILE" 2>/dev/null || true)"
[[ -z "$TOKEN" ]] && exit 0

# Fire-and-forget POST with 5s timeout. Detach so the agent never waits.
(
  curl -fsS --max-time 5 \
    -X POST "${RELAY%/}/v1/notify" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$BODY" >/dev/null 2>&1
) &
disown 2>/dev/null || true

exit 0
