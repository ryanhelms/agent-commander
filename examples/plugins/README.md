# Writing an Agent Commander plugin

A plugin gives Commander's coordinators new read tools. It is a folder with a `plugin.json` manifest and a program that serves [MCP](https://modelcontextprotocol.io) over stdio. Write the program in any language. [hello](hello) is a complete example in plain Node with no dependencies. [Design and security model](../../design/PLUGINS.md)

## Try the example

```sh
agentctl plugin install examples/plugins/hello
agentctl plugin grant example.hello.echo@1 --project /absolute/path/to/checkout --settings '{"greeting":"Howdy"}'
agentctl plugin grant example.hello.project_files@1 --project /absolute/path/to/checkout
make reload SERVICE=1
```

Start a coordinator in that checkout and ask it to list its project extensions. It finds both tools through `commander_list_tools` and calls them with `commander_call_tool`.

## Write your own

1. Write an MCP server that lists your tools with JSON Schema inputs (`"type": "object"`, no remote `$ref`) and answers `tools/call`. An official SDK handles the protocol, or copy the hand-written loop in [hello/server.mjs](hello/server.mjs).
2. Read the project scope from the call's `_meta`:
   - `_meta["agentcommander/scope"]`: `run_id`, `worker_id` and `project_path`, the resolved checkout the tool was granted to.
   - `_meta["agentcommander/settings"]`: the settings from the grant, already validated against your `settings_schema`.
3. Return structured content or a JSON text block, under 64 KiB, within five seconds. Return `isError: true` with a short message when you decline; the agent sees the message.
4. Write `plugin.json`:

| Field | Meaning |
| --- | --- |
| `schema` | Always `1`. |
| `id` | Dotted lowercase, such as `acme.jira`. Your tool IDs must start with it. |
| `version` | Your release, such as `1.2.0`. |
| `name`, `description` | Shown in `agentctl plugin list`. |
| `command` | The program and its arguments. Use a path inside the folder, such as `bin/server`, or a program on `PATH`, such as `node` or `python3`. |
| `env_allow` | Host variables your plugin may read, such as `JIRA_TOKEN`. Everything else is removed. |
| `contributes.tools` | One entry per tool: `mcp_tool` (your MCP name), `id`, integer `version`, `action: "read"`, and optional `description` to override the MCP one. |
| `settings_schema` | Optional JSON Schema for per-project settings. Without it, grants cannot carry settings. |

5. Install it with `agentctl plugin install ./your-plugin`. Install runs your server once to read its tools, so fix anything it reports and install again. Raise a tool's `version` when its input or meaning changes; grants name the exact version. Installing a release that no longer serves an existing grant (a tool's version raised or a tool dropped, or settings the new schema refuses) fails and lists those grants: revoke them, install, then grant again. `data` and `plugin.log` can't be used as a release version.

## What your plugin gets

- **Its own process.** Started on first use, restarted after it exits or misses a deadline, and stopped after fifteen idle minutes.
- **A clean environment:** `PATH`, `TMPDIR`, locale, your `env_allow` variables, and `AGENT_COMMANDER_PLUGIN_ID`, `AGENT_COMMANDER_PLUGIN_VERSION`, `AGENT_COMMANDER_PLUGIN_DIR` (your installed files) and `AGENT_COMMANDER_PLUGIN_DATA` (a private writable folder, also `HOME`). It never sees Commander's token or sockets.
- **A log.** Anything you write to stderr goes to `plugins/<id>/plugin.log` in the Commander state directory (`~/Library/Application Support/Agent Commander`, or `$AGENT_COMMANDER_HOME`). Never write logs to stdout; it carries the protocol.
- **Pinned files.** Install records a digest of your folder. If the installed files change, Commander refuses to run the plugin until you reinstall. Keep caches and state in `AGENT_COMMANDER_PLUGIN_DATA`.
