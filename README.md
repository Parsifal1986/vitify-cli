# Vitify CLI

Push notifications from [Claude Code](https://claude.com/claude-code) and
[Codex](https://github.com/openai/codex) to your Apple Watch — so you can step
away while your agent works, and get a haptic the moment it stops or needs you.

- **Done** → your watch buzzes with the first line of the agent's last reply.
- **Needs your input** → time-sensitive haptic with the question.
- **Permission requested** (Codex) → same.
- Tap **Got it** to dismiss, **Remind me in 10m** to snooze.

## Install

You'll need the [**Vitify**](#) iOS + watch app installed first (TestFlight
invite required — open an issue or contact the maintainer).

Once the watch app is paired with your iPhone, install the CLI on each
machine where you run Claude Code or Codex:

```bash
curl -fsSL https://raw.githubusercontent.com/Parsifal1986/vitify-cli/master/install.sh | bash
```

What this does:

1. Writes `~/.claude/agent-notify-notify.sh` (the hook helper).
2. Writes `~/.local/bin/agent-notify` (the CLI).
3. Writes `~/.config/agent-notify/relay` (the server URL).
4. Idempotently merges hook entries into `~/.claude/settings.json` and
   `~/.codex/hooks.json` — does not clobber existing hooks.

Dependencies: `bash`, `curl`, `jq` (`brew install jq` on macOS).

## Pair

On your watch, open Vitify → tap **Pair a Machine**. A 6-digit pin appears
(valid 5 minutes). On the Mac:

```bash
agent-notify pair
```

Enter the pin. Done — pushes go from your CLI agents to your wrist.

## Commands

```
agent-notify pair       Pair this machine with the watch
agent-notify status     Show config + paired state
agent-notify test       Send a synthetic "done" notification
```

## Configuration

| Env var               | Default                                                          |
|-----------------------|------------------------------------------------------------------|
| `AGENT_NOTIFY_RELAY`  | Read from `~/.config/agent-notify/relay`                         |
| `AGENT_NOTIFY_CONFIG` | `~/.config/agent-notify`                                         |
| `VITIFY_BIN_DIR`      | (install-time) `~/.local/bin`                                    |
| `VITIFY_VERSION`      | (install-time) `latest`                                          |

To switch relays (e.g. self-hosting), overwrite `~/.config/agent-notify/relay`
or set `AGENT_NOTIFY_RELAY` in your shell.

## Uninstall

```bash
rm ~/.local/bin/agent-notify
rm ~/.claude/agent-notify-notify.sh
rm -rf ~/.config/agent-notify
# then manually remove the Vitify hook entries from
# ~/.claude/settings.json and ~/.codex/hooks.json
```

## Privacy

Hook payloads include: the agent's last assistant message (truncated to 300
chars), session id, working directory, hostname, hook event name. Nothing
else. The relay only stores notification metadata long enough to deliver +
ack (30-day TTL), and your device tokens (hashed).

## License

MIT.
