# Harnesses

The Harnesses mode lists the AI harnesses this Mac can run, shows whether each one is installed and signed in, and signs one in with its own login command. Issue: ryanhelms/agent-commander#60.

## Increment 1 (this change)

- The service owns the harness catalog, the status probes and the change watches (`internal/harness`).
- The cockpit reads one live stream and draws the Harnesses mode from it.
- Sign in and Install run the harness's own command in a dedicated tmux session. The cockpit attaches to it with the native terminal viewer. Credentials never pass through Commander.
- Status changes reach the cockpit within about 2 s of a login or logout, without running any status command on a timer (see "How status stays current").

Later increments: SSH and headless hosts, update checks with the latest version, usage limits, catalog delivery through the signed adapter catalog refresh, FSEvents in place of the once-a-second file comparison, flagging running workers whose sign-in lapses, and Add your own harness (built on the ACP profile registry).

Codex runs in Commander only with `AGENT_COMMANDER_CODEX_PROFILE` set to a dedicated profile. Without it, the page reports Codex sign-in as unknown and says why.

## API (owner socket only)

Every route refuses an `Authorization` header and hosted callers, like the other owner-only routes.

| Route | Does |
|---|---|
| `GET /v1/harnesses` | Returns the current list. |
| `GET /v1/harnesses/events` | Server-sent events. The first frame is the full list; a frame follows each change. A `: heartbeat` comment every 10 s. |
| `POST /v1/harnesses/{id}/check` | Re-probes one harness now and returns it. |
| `POST /v1/harnesses/{id}/login` | Starts the harness's login command in its own tmux session and returns a terminal attachment. |
| `POST /v1/harnesses/{id}/install` | Starts the install command the same way and returns a terminal attachment. |
| `PUT /v1/harnesses/{id}/settings` | Body `{"enabled": bool, "default_model": "…"}`. Returns the harness. |

A list frame and `GET /v1/harnesses` share this shape:

```json
{
  "harnesses": [
    {
      "id": "claude",
      "name": "Claude Code",
      "vendor": "Anthropic",
      "kind": "agent",
      "group": "vendor",
      "website": "https://claude.com/claude-code",
      "managed": true,
      "verified": true,
      "installed": true,
      "executable": "/Users/me/.local/bin/claude",
      "version": "2.1.332",
      "auth": {
        "state": "signed_in",
        "account": "me@example.com",
        "plan": "max",
        "method": "claude.ai",
        "expires_at": "2026-12-23T09:55:41Z",
        "source": "status_command",
        "detail": ""
      },
      "acp": { "adapter": "claude-agent-acp", "installed": true, "mode": "acp" },
      "install": { "available": true, "display": "npm install -g @anthropic-ai/claude-code" },
      "login": { "available": true, "display": "claude auth login" },
      "settings": { "enabled": true, "default_model": "" },
      "models": ["opus", "sonnet", "haiku"],
      "checked_at": "2026-11-26T22:40:00Z",
      "changed": "auth"
    }
  ]
}
```

Field values:

- `kind`: `agent` (a coding harness) or `runner` (a local model runner such as Ollama).
- `group`: `vendor`, `open_source`, `ide` or `runner`. The cockpit may use it to order Available.
- `managed`: Commander can start runs with it today (Claude Code and Codex).
- `run_blocker`: present only on a managed harness that cannot start a run now. It holds the launcher's own reason, for example a missing adapter or Codex profile. The cockpit shows it in the inspector, and the New run sheet disables the harness whenever it is present, whatever `auth.state` says.
- `verified`: the probe was checked against the real CLI. An unverified harness reports sign-in from its credential files only, and `auth.source` says so.
- `auth.state`: `signed_in`, `signed_out`, `expired`, `not_required` (runners), `unknown` (installed, but no way to tell), or `not_installed`.
- `auth.source`: `status_command`, `credential_file`, `environment` (an API key variable is set) or `none`.
- `acp.mode`: `acp`, `legacy` (Claude Code in tmux without its adapter), `adapter_missing` (Commander needs the adapter to run this harness and cannot find it) or `unsupported` (no ACP adapter in the catalog). The service looks for an adapter where `internal/provider` does: `AGENT_COMMANDER_CLAUDE_ACP` or `AGENT_COMMANDER_CODEX_ACP`, then `AGENT_ACP_HARNESS_DIR`, then `PATH`.
- `changed`: present only in a stream frame, on the harnesses that changed since the previous frame: `installed`, `auth`, `version` or `settings`. The cockpit raises a Needs you item and a macOS notification when a harness's `auth.state` moves from `signed_in` to `signed_out` or `expired`.

A terminal attachment, from login and install:

```json
{ "harness_id": "codex", "purpose": "login", "socket_path": "/private/tmp/tmux-501/ac-…-login", "session_id": "$3" }
```

The session ends when the command exits. The service re-checks the harness then, so the stream carries the new state.

## How status stays current

The service never runs a status command on a timer. A watcher loop compares cheap file fingerprints once a second and re-probes a harness only when something it depends on changed:

- the harness's credential files and folders (for example `~/.codex/auth.json`, `~/.gemini/oauth_creds.json`)
- Claude Code's `Claude Code-credentials` Keychain item: when the login keychain file changes, the service reads the item's modification date (attributes only, never the secret)
- the folders on `PATH` and the usual install folders, to catch installs and removals
- the end of a login or install session
- the stored expiry time, where the status command reports one
- a request from the cockpit (`check`) when the app becomes active

## Catalog

`internal/harness/harnesses.json` is embedded in the service. Each entry names its binaries, install command, login command, status probe, credential locations and ACP adapter. Moving it into the signed adapter catalog refresh is a later increment.
