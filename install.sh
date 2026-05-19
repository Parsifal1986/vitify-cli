#!/usr/bin/env bash
# Vitify CLI installer — wires Claude Code / Codex agent hooks to your Apple Watch.
#
# Remote install:
#   curl -fsSL https://raw.githubusercontent.com/Parsifal1986/vitify-cli/main/install.sh | bash
#
# Local install (from a clone):
#   ./install.sh
#
# Env overrides:
#   VITIFY_REPO        owner/repo on GitHub        (default: Parsifal1986/vitify-cli)
#   VITIFY_VERSION     git tag or "latest"         (default: latest)
#   VITIFY_RELAY       relay base URL              (default: baked-in production)
#   VITIFY_BIN_DIR     where to install CLI        (default: ~/.local/bin)

set -euo pipefail

# ─── Config ───────────────────────────────────────────────────────────────
VITIFY_REPO="${VITIFY_REPO:-Parsifal1986/vitify-cli}"
VITIFY_VERSION="${VITIFY_VERSION:-latest}"
VITIFY_RELAY="${VITIFY_RELAY:-https://9mvmal2xql.execute-api.us-east-1.amazonaws.com}"
VITIFY_BIN_DIR="${VITIFY_BIN_DIR:-$HOME/.local/bin}"

NOTIFY_DST="$HOME/.claude/agent-notify-notify.sh"
AGENT_DST="$VITIFY_BIN_DIR/agent-notify"
CONFIG_DIR="$HOME/.config/agent-notify"
RELAY_FILE="$CONFIG_DIR/relay"
CLAUDE_CFG="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
CODEX_CFG="${CODEX_HOOKS:-$HOME/.codex/hooks.json}"

# ─── Dependency check ─────────────────────────────────────────────────────
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Vitify install: missing required tool '$1'." >&2
    case "$1" in
      jq)   echo "  Install with: brew install jq" >&2 ;;
      curl) echo "  Install with: brew install curl" >&2 ;;
    esac
    exit 1
  }
}
require_cmd curl
require_cmd jq

# ─── Source files: prefer local clone, else download ──────────────────────
SCRIPT_DIR="$( (cd "$(dirname "${BASH_SOURCE[0]:-/dev/null}")" 2>/dev/null && pwd) || echo "" )"

if [[ "$VITIFY_VERSION" == "latest" ]]; then
  ASSET_BASE="https://github.com/${VITIFY_REPO}/releases/latest/download"
else
  ASSET_BASE="https://github.com/${VITIFY_REPO}/releases/download/${VITIFY_VERSION}"
fi

fetch() {
  local name="$1" out="$2" local_path="$SCRIPT_DIR/$1"
  if [[ -n "$SCRIPT_DIR" && -r "$local_path" ]]; then
    echo "Using local $name"
    cp "$local_path" "$out"
  else
    echo "Downloading $name from $ASSET_BASE"
    curl -fsSL "$ASSET_BASE/$name" -o "$out" || {
      echo "Failed to download $name." >&2
      echo "  Tried: $ASSET_BASE/$name" >&2
      echo "  Check VITIFY_REPO ($VITIFY_REPO) and VITIFY_VERSION ($VITIFY_VERSION)." >&2
      exit 1
    }
  fi
}

# ─── Install scripts ──────────────────────────────────────────────────────
mkdir -p "$(dirname "$NOTIFY_DST")" "$VITIFY_BIN_DIR" "$CONFIG_DIR"

fetch notify.sh "$NOTIFY_DST"
chmod +x "$NOTIFY_DST"

fetch agent-notify "$AGENT_DST"
chmod +x "$AGENT_DST"

umask 077
printf '%s' "$VITIFY_RELAY" > "$RELAY_FILE"
chmod 0600 "$RELAY_FILE"

# ─── Hook merge (idempotent) ──────────────────────────────────────────────
merge_hook() {
  local config_path="$1" event="$2" arg="$3"
  mkdir -p "$(dirname "$config_path")"
  [[ -f "$config_path" ]] || echo '{}' > "$config_path"

  local cmd="$NOTIFY_DST $arg"
  local tmp; tmp="$(mktemp)"

  jq \
    --arg event "$event" \
    --arg cmd   "$cmd" \
    '
    .hooks                                  //= {}
    | .hooks[$event]                        //= []
    | .hooks[$event] |= (
        if any(.[]; .matcher == "") then
          map(
            if .matcher == "" then
              .hooks //= []
              | .hooks |= (
                  if any(.[]; .type == "command" and .command == $cmd) then .
                  else . + [{type:"command", command:$cmd, timeout:5}]
                  end
                )
            else . end
          )
        else
          . + [{matcher:"", hooks:[{type:"command", command:$cmd, timeout:5}]}]
        end
      )
    ' "$config_path" > "$tmp"
  mv "$tmp" "$config_path"
}

merge_hook "$CLAUDE_CFG" "Stop"              "done"
merge_hook "$CLAUDE_CFG" "Notification"      "needs_input"
# Codex has no Notification event; PermissionRequest is the closest signal.
merge_hook "$CODEX_CFG"  "Stop"              "done"
merge_hook "$CODEX_CFG"  "PermissionRequest" "needs_input"

# ─── Next steps ───────────────────────────────────────────────────────────
echo
echo "Vitify installed ✓"
echo "  Hook helper: $NOTIFY_DST"
echo "  CLI:         $AGENT_DST"
echo "  Relay:       $VITIFY_RELAY"
echo "  Claude hooks updated: $CLAUDE_CFG"
echo "  Codex hooks updated:  $CODEX_CFG"
echo

case ":$PATH:" in
  *":$VITIFY_BIN_DIR:"*) ;;
  *)
    echo "⚠  $VITIFY_BIN_DIR is not in your PATH."
    echo "   Add this to your ~/.zshrc (or ~/.bashrc):"
    echo
    echo "     export PATH=\"$VITIFY_BIN_DIR:\$PATH\""
    echo
    echo "   Then open a new terminal."
    echo
    ;;
esac

cat <<EOF
Next steps:
  1. On your Apple Watch, open Vitify and tap "Pair a Machine" — a 6-digit pin appears.
  2. On this Mac, run:

       agent-notify pair

  3. Type the pin. You're done — Claude Code / Codex will buzz your watch from now on.
EOF
