#!/usr/bin/env bash
# Hook entrypoint invoked by Claude Code / Codex.
# Reads hook JSON from stdin, builds an event-specific summary, fires a
# fire-and-forget HTTPS POST to the relay. Must NEVER exit non-zero — a
# non-zero exit from a hook can block the agent.
#
# Send delay: every notification is held in a detached sleeper for a short
# window before firing. Any subsequent hook for the same session (Stop,
# Notification, or a UserPromptSubmit invoked with `cancel`) kills the
# pending sleeper. If the user replies before the window expires, the
# notification is dropped — they're already at the keyboard.
#
# Quiescence timer: if Claude's last assistant turn invoked a self-resume
# tool (ScheduleWakeup / CronCreate / Monitor / backgrounded Bash), the
# window is extended so we don't page while Claude is still iterating.

set -u

EVENT_KIND="${1:-done}"   # done | needs_input | cancel
SEND_DELAY=30             # default window before firing — gives the user a
                          # chance to respond before we page
QUIESCE_SECONDS=600       # extended window when Claude has a pending self-wake

CONFIG_DIR="${AGENT_NOTIFY_CONFIG:-$HOME/.config/agent-notify}"
TOKEN_FILE="$CONFIG_DIR/token"
RELAY_FILE="$CONFIG_DIR/relay"
LOG_FILE="$CONFIG_DIR/debug.log"
RELAY="${AGENT_NOTIFY_RELAY:-}"

# Opt-in diagnostic logging. Enable with `touch ~/.config/agent-notify/debug.log`,
# disable with `rm`. Records timestamps, event kinds, session IDs, sleeper PIDs,
# and curl exit codes — never the bearer token, relay URL, or payload.
_ts() {
  perl -MTime::HiRes -e \
    'my @t=Time::HiRes::gettimeofday(); printf "%d.%03d\n", $t[0], int($t[1]/1000)' \
    2>/dev/null || date '+%s'
}
log_event() {
  [[ -f "$LOG_FILE" ]] || return 0
  printf '%s pid=%d session=%s kind=%s hook=%s %s\n' \
    "$(_ts)" "$$" "${SESSION_ID:-unset}" "$EVENT_KIND" "${HOOK_EVENT:-unset}" "$*" \
    >> "$LOG_FILE" 2>/dev/null || true
}

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
TRANSCRIPT_PATH="$(printf '%s' "$PAYLOAD" | jq -r '.transcript_path // ""' 2>/dev/null || echo "")"
[[ -z "$SESSION_ID" ]] && SESSION_ID="unknown"

PENDING_MARKER="/tmp/agent-notify-pending-${SESSION_ID}"

cancel_pending() {
  if [[ -f "$PENDING_MARKER" ]]; then
    local old_pid
    old_pid="$(cat "$PENDING_MARKER" 2>/dev/null || echo "")"
    log_event "cancel_pending found_pid=${old_pid:-empty}"
    [[ -n "$old_pid" ]] && kill "$old_pid" 2>/dev/null || true
    rm -f "$PENDING_MARKER" 2>/dev/null || true
  else
    log_event "cancel_pending no_marker"
  fi
}

log_event "hook_start"

# UserPromptSubmit short-circuit: the user is at the keyboard, so any
# pending notification for this session is no longer interesting.
if [[ "$EVENT_KIND" == "cancel" ]]; then
  cancel_pending
  exit 0
fi

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
  PreToolUse)
    # Claude Code: arm a sleeper before every approval-prone tool call.
    # Paired with PostToolUse → cancel, so quick/auto-allowed tools never
    # buzz; only tools that block on user permission past the send window do.
    TOOL="$(printf '%s' "$PAYLOAD" | jq -r '.tool_name // ""' 2>/dev/null || echo "")"
    DETAIL="$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // .tool_input.file_path // .tool_input.description // ""' 2>/dev/null || echo "")"
    if [[ -n "$DETAIL" ]]; then
      SUMMARY="${TOOL}: ${DETAIL}"
    else
      SUMMARY="${TOOL:-Tool} pending approval"
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

fire_notification() {
  curl -fsS --max-time 5 \
    -X POST "${RELAY%/}/v1/notify" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$BODY" >/dev/null 2>&1
}

# Any prior sleeper for this session is now stale — kill it before we
# decide what to do next.
cancel_pending

# Detect self-resume: scan only the most recent assistant turn in the JSONL
# transcript for a tool call that implies Claude will come back on its own.
# Older turns don't matter — what we care about is whether *this* Stop will
# be followed by a self-triggered wake.
#   ScheduleWakeup / CronCreate  → explicit scheduled resume
#   Monitor                      → streaming a background task, will resume
#                                  on each event
#   Bash w/ run_in_background    → background task whose completion will
#                                  re-trigger Claude
HAS_PENDING_WAKE=false
if [[ "$HOOK_EVENT" == "Stop" && -n "$TRANSCRIPT_PATH" && -r "$TRANSCRIPT_PATH" ]]; then
  LAST_ASSISTANT="$(awk '/"type":"assistant"/ {last=$0} END {print last}' "$TRANSCRIPT_PATH" 2>/dev/null || true)"
  if [[ -n "$LAST_ASSISTANT" ]]; then
    WAKE_HIT="$(printf '%s' "$LAST_ASSISTANT" | jq -r '
      .message.content[]?
      | select(.type=="tool_use")
      | select(
          (.name == "ScheduleWakeup") or
          (.name == "CronCreate") or
          (.name == "Monitor") or
          (.name == "Bash" and (.input.run_in_background == true))
        )
      | .name
    ' 2>/dev/null || true)"
    [[ -n "$WAKE_HIT" ]] && HAS_PENDING_WAKE=true
  fi
fi

if $HAS_PENDING_WAKE; then
  DELAY="$QUIESCE_SECONDS"
else
  DELAY="$SEND_DELAY"
fi

log_event "sleeper_arming delay=$DELAY pending_wake=$HAS_PENDING_WAKE"

# Spawn a detached sleeper. A subsequent hook for this session (Stop,
# Notification, PermissionRequest, or UserPromptSubmit→cancel) kills this
# PID via cancel_pending above and the curl never runs. Burst suppression
# is handled by that cancellation plus the quiesce window above — no
# separate post-fire debounce is needed.
(
  log_event "sleeper_run delay=$DELAY"
  sleep "$DELAY"
  log_event "sleeper_fired"
  fire_notification
  log_event "curl_done exit=$?"
  rm -f "$PENDING_MARKER" 2>/dev/null || true
) >/dev/null 2>&1 &
SLEEPER_PID=$!
disown 2>/dev/null || true
printf '%s\n' "$SLEEPER_PID" > "$PENDING_MARKER"
log_event "sleeper_armed pid=$SLEEPER_PID"

exit 0
