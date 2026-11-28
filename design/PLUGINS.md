# User plugins

Users add their own tools to Commander as plugins, without compiling them into `agentctl`. Increment 1 ships read tools. [Issue #152](https://github.com/ryanhelms/agent-commander/issues/152) · [Package](../internal/plugins) · [Example plugin](../examples/plugins/hello)

## Why this shape

Commander already had four extension seams. None of them took user code.

| Seam | Who could extend it before plugins |
| --- | --- |
| Scoped project tools (`internal/toolregistry`, granted in `tool-grants.json`, reached through `commander_list_tools` / `commander_call_tool`) | Compiled Go only. Configuration can grant a registered version but cannot install code. |
| Session companions (`toolregistry.RegisterCompanion`) | First-party, compiled in. |
| Harness adapters (`harness.Register`, `acp-profiles.json`) | ACP profiles are out of process and user-supplied, but hand-edited and unversioned. |
| Relay strategies and transports | Compiled in. [MULTIPLAYER-RELAY.md](MULTIPLAYER-RELAY.md) requires third-party extensions to run out of process behind a version-negotiated RPC adapter with deadlines, size limits and scoped credentials. |

Plugins extend the scoped tool seam, because its grant model, schema validation, per-project scoping, MCP surface and agent prompt hint already exist. What was missing was a `toolregistry.Tool` backed by code the user installed. The relay document's rule decides the boundary: plugin code never runs in Commander's process. Go's `plugin` package is ruled out for the reasons that document cites, and in-process code would hold the service's privileges.

## Package

A plugin is a directory with `plugin.json` at its root and a program that serves MCP over stdio. MCP is the RPC: Commander already embeds the Go MCP SDK, it negotiates a protocol version at `initialize`, and authors have official SDKs in most languages.

```json
{
  "schema": 1,
  "id": "acme.jira",
  "version": "1.2.0",
  "name": "Jira lookups",
  "command": ["node", "server.mjs"],
  "env_allow": ["JIRA_TOKEN"],
  "contributes": {
    "tools": [{ "mcp_tool": "get_issue", "id": "acme.jira.get_issue", "version": 1, "action": "read" }]
  },
  "settings_schema": { "type": "object", "properties": { "site": { "type": "string" } } }
}
```

- `id` follows the scoped tool ID rule. Each tool ID must start with the plugin ID, so plugin tools share the registry's namespace without colliding.
- `command[0]` is either a path inside the package or a bare program name looked up on `PATH`. Install records the absolute path a bare name resolved to; the service uses it when its own `PATH` lacks the program, as when the app starts the service.
- `env_allow` names host variables the plugin may read. Names starting with `AGENT_COMMANDER_`, `COMMANDER_`, `DYLD_` or `LD_`, and `SSH_AUTH_SOCK`, `PATH` and `HOME`, are refused.
- Each tool maps one MCP tool to a Commander tool ID and integer version. `action` must be `read`.
- `settings_schema`, when present, validates the per-project settings a grant carries. Without it, grants cannot carry settings.

## Install, grant, remove

```sh
agentctl plugin install ./my-plugin
agentctl plugin grant acme.jira.get_issue@1 --project /abs/checkout --settings '{"site":"acme"}'
agentctl plugin list
agentctl plugin revoke acme.jira.get_issue [--project /abs/checkout]
agentctl plugin remove acme.jira
```

`install` validates the manifest and refuses a tool ID that Commander or another plugin already registers. It copies the package into a staging directory under `$STATE/plugins/`. Regular files, directories and symlinks that stay inside the package are accepted; anything else is refused. It starts the copy once with the plugin environment, completes `initialize` and `tools/list` within ten seconds, and checks that every contributed MCP tool exists with a self-contained object input schema. It then freezes each schema and description into `$STATE/plugins/installed.json` and moves the package to `$STATE/plugins/<id>/<version>/`. The record pins a SHA-256 over the package tree: each entry's path, kind, executable bit and content or link target. A plugin cannot change its schema without a reinstall. Installing another version replaces the previous one and keeps the plugin's data directory. The versions `data` and `plugin.log` are reserved, in any case, because those names sit beside the version directories. Before it changes anything, an upgrade checks every existing grant of the plugin's tools against the new version: the tool must still exist at the granted version, and the grant's settings must match the new `settings_schema`. Otherwise install fails and names each grant, because the service refuses to start on a grant it can't bind. The operator revokes those grants, installs, and grants the new versions.

Installing grants nothing. `grant` checks the tool version and the settings against the frozen schema, then writes the entry into `tool-grants.json` in the format the registry already reads. Grants for compiled tools pass through untouched. `remove` withdraws every grant of the plugin's tools before deleting its files. The service reads grants at startup, so grant changes take effect at the next restart (`make reload SERVICE=1`).

## Runtime

At service start, `plugins.Load` turns `installed.json` into ordinary `toolregistry.Tool` values. `agentctl serve` passes them to `toolregistry.Load` beside the compiled tools. Nothing changes in `mcpbridge`, the runner's allowed tools or the agent prompt: plugin tools appear in `commander_list_tools` like `linear.issue.read`, and the existing service path applies the bearer check, project grant, schema validation, five-second deadline and 64 KiB result limit.

Each tool uses `Bind`. Binding validates the grant's settings and warms the plugin's process in the background, so the first call does not pay for process start inside the five-second deadline. The bound handler is an [Adapter](../.context/design-patterns/adapter.md) from `toolregistry.Handler` to an MCP `tools/call`. Each plugin has one supervised process, a [Service Activator](../.context/design-patterns/service-activator.md):

- It starts on first use and is shared by concurrent calls. Before each start, the supervisor checks the installed files against the pinned digest. The start runs on its own, with a ten-second limit, and every caller, including the one that began it, waits on it or its own deadline, so a slow check or handshake never holds a call past five seconds.
- When the process exits, or a call misses its deadline or breaks the pipe, the supervisor drops it and the next call starts a fresh one. A failed start is retried after two seconds.
- It stops after fifteen idle minutes and when the service stops. The process runs in its own process group, which is killed when its session ends.
- The environment contains only `PATH`, `TMPDIR`, locale and user names, the `env_allow` variables, and `AGENT_COMMANDER_PLUGIN_ID`, `_VERSION`, `_DIR` and `_DATA`. `HOME` is the plugin's private data directory. The process never receives `AGENT_COMMANDER_TOKEN`, a Commander socket or the service's credentials.
- Each call carries `_meta["agentcommander/scope"]` with `run_id`, `worker_id` and the resolved `project_path`, and `_meta["agentcommander/settings"]` with the grant's settings.
- Structured content becomes the tool result. A single JSON text block passes through, and other text is wrapped as `{"text": ...}`. A tool error becomes `{"error": text}`, so the agent sees why the plugin declined, as data. Transport failures and refused plugins return the registry's fixed `scoped tool unavailable` outcome.
- Plugin stderr goes to `$STATE/plugins/<id>/plugin.log`, truncated once it passes 4 MiB.

A plugin whose installed files no longer match its digest is reported at startup, and `agentctl plugin list` shows it as a problem. Its tools stay registered so existing grants still load and other tools keep working, but every call returns `scoped tool unavailable` until the plugin is reinstalled.

## Cockpit Plugins page (increment 2)

The cockpit's **Plugins** mode lists installed plugins, their problems and their per-project grants, grants and revokes tools, and shows the tail of `plugin.log`. It talks to owner-only service routes ([`internal/service/plugins.go`](../internal/service/plugins.go)). A request that carries a bearer credential or arrives through the hosted relay is refused with 403, as for the harness routes. [Issue #180](https://github.com/ryanhelms/agent-commander/issues/180)

| Route | Does |
| --- | --- |
| `GET /v1/plugins` | Installed plugins with their tools, settings schema, grants and a `problem` when the installed files fail the digest check |
| `POST /v1/plugins/grants` | `{"tool","version","project","settings"?}` through `plugins.Grant`, so the version, the project directory and the settings are checked exactly as `agentctl plugin grant` checks them |
| `POST /v1/plugins/grants/revoke` | `{"tool","project"}` through `plugins.Revoke`. Only tools an installed plugin provides; compiled tool grants are not the page's to change |
| `GET /v1/plugins/{id}/log` | The last 16 KiB of `plugin.log`, starting at a line boundary |

Grant changes return the same body as the list. The service still reads plugins and grants only at startup, so the routes keep a snapshot of what it loaded. Each grant carries `active`, and the plugin `loaded`, comparing the file with that snapshot; `restart_required` is true when anything differs, including a revoked grant the service still holds. The page says so and the change applies at the next service restart.

For `adag.mqtt` the page adds a native MQTT panel. It reads the MQTT Bridge daemon's own loopback HTTP API (`http://127.0.0.1:18830`: `/api/status`, `/api/topics`, `/api/messages` and the `/api/stream` server-sent events) directly, not through Commander, and shows broker statistics, a topic tree, the live message list and a payload inspector. Publishing stays in the bridge's web UI.

## Limits of increment 1

The process boundary keeps plugin code out of Commander's address space and credentials. It does not sandbox the plugin: the process runs as the user and can read what the user can read. Install only plugins you trust, as you would any program. Later increments add capabilities that each need their own authorization story.

| Increment | Adds | Needs first |
| --- | --- | --- |
| 2 | A Plugins page in the cockpit: list, grant per project, view the log (shipped, see above) | DESIGN.md additions, frontend owner |
| 3 | `contributes.harnesses`: a plugin ships an ACP adapter that becomes an `acp-profiles.json` entry | Reuse of the ACP profile validation |
| 4 | `write` tools | Per-call human approval through the elicitation and Needs You path |
| 5 | An optional macOS sandbox profile per plugin with declared network and filesystem capabilities | A decision on depending on `sandbox-exec` |

## Verification

| Exercise | Check |
| --- | --- |
| Install the example, grant two tools to one checkout, call them through `agentctl mcp` | `TestPluginToolsThroughAgentctlMCP`: a coordinator lists and calls both, the settings and resolved project path reach the plugin, and a coordinator in another checkout lists nothing |
| A plugin reads `AGENT_COMMANDER_TOKEN` or an undeclared variable | `TestInstallGrantAndCall`: both empty, declared variables present |
| A file is added inside the installed plugin | `TestTamperedPluginIsRefused`: a startup problem names the digest, and the call is unavailable |
| A call hangs | `TestHungCallRestartsPlugin`: the call fails at its deadline, and the next call runs in a new process |
| A tool ID collides, or a contributed MCP tool is missing | `TestInstallRejectsCollisions`, `TestInstallRejectsMissingMCPTool` |
| Remove a plugin | `TestRemoveWithdrawsGrants`: its grants go, other grants stay |

`TestPluginGrantRevokeAndRestartState`, `TestPluginListReportsTamperedFiles`, `TestPluginLogTail` and `TestPluginRoutesServeOnlyTheOwner` cover the cockpit routes.

Run the end-to-end proof with `AGENT_COMMANDER_TEST_INTEGRATION=1 go test -count=1 ./cmd/agentctl -run '^TestPluginToolsThroughAgentctlMCP$'`. It needs `node` on `PATH`.
