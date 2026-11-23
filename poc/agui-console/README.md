# Focused Claude console proof of concept

One Claude Code conversation runs in a real, attachable tmux pane. A local CopilotKit runtime streams AG-UI events to the React console in a native macOS WebKit window. The fixture is a fictional release-planning task. The launcher creates a fresh private data directory for each demo and copies in the sample document.

## Build and open

Use macOS 26, Swift and the macOS 26 SDK, Go, Node.js, npm, tmux and a signed-in Claude Code CLI. Run these commands from the project root.

```sh
npm --prefix poc/agui-console ci --no-audit --no-fund
sh poc/agui-console/build.sh
npm --prefix poc/agui-console run launch
```

Select **Start session**. Claude reads the sample and asks for a release label. Select **View request** in the footer to focus the inline prompt. Return sends the reply, and Shift-Return inserts a newline. Expand a tool row to see its output. The proof keeps one conversation per launch. Quit the console to end the local runtime and stop any still-active proof run.

## Boundaries

- The Claude runner retains bounded, ordered text and tool events alongside its tmux text. The TypeScript adapter polls the isolated Go API and translates these records to standard AG-UI lifecycle, message, tool, and state events. The shipped CopilotKit runtime delivers the UI stream. Text arrives when Claude emits structured blocks.
- Request cards submit a specific Go request ID. The API owns request resolution and Claude reads the reply through MCP. The backend uses EIP Request-Reply and a Correlation Identifier for this path. The provider-to-AG-UI adapter is a Message Translator. [Project pattern decisions](../../design/PATTERN-DECISIONS.md)
- The native shell gives the window its macOS title bar. The full-width React scrollback uses monospaced text, semantic ink colors, collapsible tool rows, and a compact, wrapping status bar. Foundation values, atoms, molecules, organisms, template and page sit under `ui/`. Ordinary terminal input is available by attaching through tmux.
- The loopback server exposes the proof through an unguessable launch URL and a same-origin session cookie. Go continues to listen on a private Unix socket. The normal cockpit, its review gallery and its live data have their own paths.

## Verified run

Computer Use started a real Claude session with Return, expanded the live `Read` row, and verified that Shift-Return created a second line while the request stayed pending. Return submitted the two-line reply. Claude returned the exact text, including a dollar sign and quotes, and the title bar and footer changed to **completed**. [Waiting for input](verification/terminal-waiting.jpg) · [Completed terminal](verification/terminal-completed.jpg)

In the redesigned footer, **View request** focused the live reply field. I sent the reply and verified that the action and reply shortcuts cleared when Claude finished. [Footer awaiting input](verification/footer-waiting.jpg) · [Footer after completion](verification/footer-completed.jpg)

Assistant output renders a small Markdown subset, including inline code and fenced blocks. Raw tool results remain available inside their disclosure rows. The connector polls the Go snapshot while CopilotKit streams the translated events to the console.
