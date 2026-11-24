# Focused Claude console proof of concept

One Claude Code conversation runs in a real, attachable tmux pane. A local CopilotKit runtime streams AG-UI events to the React console in a native macOS WebKit window. The fixture is a fictional release-planning task. The launcher creates a fresh private data directory for each demo and copies in the sample document.

To embed an existing Commander worker in a separate application, run the standalone browser example with the locally packaged connector. It includes the CopilotKit runtime, its browser client, addressed replies and original tool results. [Independent app](../../examples/copilotkit/README.md)

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

## Connect an independent local runtime

The connector ships as its own Node package. To build and install the staged package from the repository root, run

```sh
mkdir -p dist/copilotkit
npm pack --ignore-scripts --pack-destination dist/copilotkit ./poc/agui-console/connector
npm --prefix /absolute/path/to/your-app install "$PWD/dist/copilotkit/agent-commander-copilotkit-0.1.4.tgz"
```

Import `connectCommanderWorker` from `@agent-commander/copilotkit` in the consuming app. [Package usage](connector/README.md)

`commander-agent.mjs` provides an AG-UI `HttpAgent` for a trusted Node backend with access to the Commander owner socket. It binds to an existing managed worker. Use the input generation from that worker after taking control through Commander. Register the agent in a CopilotKit runtime's `agents` map, or exercise it directly.

```js
import { connectCommanderWorker } from './commander-agent.mjs';

const { agent, reply, resume } = connectCommanderWorker({ socketPath, workerId });
agent.addMessage({ id: messageId, role: 'user', content: prompt });
await agent.runAgent({ runId, forwardedProps: { generation } });
```

Subscribe to state while the run is active so the app can show pending requests and call `reply` with the exact request ID. After an interruption, call `resume({ runId })` with the originally submitted ID. The connector looks up the receipt even if the first response ended before the operation ID arrived. If Commander never accepted the original run, a separate explicit retry can reuse the original run ID, prompt, and input generation.

The 0.1.5 connector reports an incomplete run when the HTTP stream ends before the AG-UI terminal event. The reference console retains the tab’s original run ID. Reload the tab to recover through a passive observation after access is restored. [Recovery and revocation verification](../../design/verification/copilotkit-live/README.md#recovering-an-interrupted-observation)

With connector 0.1.6, expand a source-linked user message in **Provider history** or the conversation. Choose **Open attachments** and then an item to preview inline image or audio bytes from its original Claude or Codex prompt. The lookup is private to the worker and distinguishes repeated media entries by position within the selected prompt. [Browser verification](../../design/verification/copilotkit-live/README.md#opening-archived-prompt-attachments)

Use `connector.readHistory({ source: 'journal', cursor, limit: 12 })` to load supplementary records for a bound local Claude or Codex session. The response uses the SDK observation envelope, with base64 fields for the retained source and a typed gap for unavailable records. Pass the next cursor back to the same source and worker. Hosted apps need the worker's `commander:history` grant. The attached reference console exposes these pages under **Session journal**.

For a live session, `readHistory({ source: 'live' })` returns a Fetch Response containing SDK observations. A normalized tool or text observation can carry the original JSON bytes in `sourceRecord.data`. A passive update can carry them in `extension.data`. For type `acp.session_update_params`, decode the base64 as UTF-8 to recover the full ACP method params, including unknown top-level members. The reference console displays that text directly and previews supported inline image and audio attachments. With `view: 'acp'`, the response contains JSON values under `update` and `paramsFields`. Use `await response.text()` and a lossless JSON reader when vendor numbers can exceed the JavaScript safe integer range.

Open **Live ACP source**, select a record, then expand **JSON-RPC envelope** to inspect the transport fields retained by Agent ACP 0.1.13. `wireProvenance.idJson` holds the original request ID token, including quotes for a string ID. `additionalFieldsJson` holds the original vendor members as JSON text. Read these strings directly to preserve large numbers and escaped IDs. When supplied, the disclosure also shows base64 byte fallbacks and counts for omitted fields. **Original record** opens the complete SDK observation, including the details of a source gap.

The released 0.1.13 worker and the installed CopilotKit connector 0.1.4 delivered 13 records across five isolated workers to a headless Chrome session. It opened every record and matched the notification, permission, result and two error envelopes against the scoped history responses. The permission ID and vendor counter both retained `9007199254740993`. The decoded tool result displayed its one-pixel PNG. The worker that disconnected before replying reported a source gap. [Error envelope in the reference console](verification/wire-error-source.png) · [Stdio verification driver](../../design/verification/transcript-coverage/capture-update-params.py)

A headless browser opened six real observations from a local Commander candidate using Agent ACP 0.1.12 and a deterministic stdio peer. Three typed records carried source records, and three between-turn records used extensions. Each open disclosure displayed the original params, and the tool result showed `UMBER-731` and decoded its one-pixel PNG. The installed CopilotKit connector 0.1.4 preserved both the absent and explicit-null `update`, nested arrays and objects, and the exact numbers `9007199254740993` and `-9007199254740999`. [Reference console capture](verification/enriched-update-source.png) · [SDK observation fixture](testdata/enriched-update-history.json) · [Reference bridge regression](attached-console.test.mjs)

Use the same client method with `source: 'live'` for retained original ACP updates, including raw tool fields and inline attachments. The reference console exposes these records under **Live ACP source**. Each detail page is scoped to the same worker as the run; the app can display the source record using its observation and tool-call identity.

Omit `source` to read **Provider history** from the same connector. Where a bound ACP harness supports session loading, the provider can restore a stopped session's retained history. The reference console shows the available text, tool details, attachments, raw updates, and explicit gaps. Historical requests appear as records. A stopped worker opens with its composer hidden.

Run `node --test commander-agent.test.mjs` in this directory to exercise the installed AG-UI client against a Unix socket fixture. The service integration test separately exercises command acceptance, request replies, tool results and reconnect through the real Commander HTTP handler.

## Connect a hosted runtime

Enable Commander's direct HTTPS listener and grant your app access to the worker. Run this connector on the CopilotKit backend and supply a function that returns the app's current audience-bound OAuth access token. The connector calls the function for each request.

```js
const { agent, workerInfo, resume, reply } = connectCommanderWorker({
  baseURL: 'https://commander.example.net',
  workerId,
  getAccessToken,
});

const response = await workerInfo();
if (!response.ok) throw new Error(`Commander denied worker access (${response.status})`);
const { generation } = await response.json();
if (generation === undefined) throw new Error('Take input control in Commander.');
agent.addMessage({ id: messageId, role: 'user', content: prompt });
await agent.runAgent({ runId, forwardedProps: { generation } });
```

While the run is active, read the pending request ID from agent state and call `reply({ requestId, answer, generation, idempotencyKey })`. Keep the token and refresh credentials on the backend. After an interrupted response, call `resume({ runId })` with the same submitted run ID. The same connector accepts the assigned relay hostname as its HTTPS origin. [Listener and grant configuration](../../README.md#direct-https-for-hosted-apps) · [Relay deployment](../../design/RELAY-DEPLOYMENT.md)

## Send an image or audio prompt

Check `promptCapabilities.image` and `promptCapabilities.audio` in the worker summary before offering those inputs. Use an ordered array of AG-UI content parts in the user message. For an image or audio part, supply `source.type = "data"`, a matching `source.mimeType`, and base64 bytes in `source.value`. Text parts use `type: "text"` and `text`. Commander preserves that order when sending the ACP prompt. Inline media shares the existing 1 MiB run request limit. Commander returns HTTP 501 for unsupported parts or sources and HTTP 400 for malformed media. The console preview displays the attachment type and MIME type. Select the worker's Live source to inspect retained attachment data. [AG-UI user messages](https://docs.ag-ui.com/concepts/messages#user-messages) · [ACP content](https://agentclientprotocol.com/protocol/v1/content) · [ACP initialization](https://agentclientprotocol.com/protocol/v1/initialization)

## Offer a frontend tool

Read `frontendTools` and `generation` from the worker summary. For a hosted app, the token and that worker's grant both need `commander:frontend-tools` in addition to the scopes for starting a run. Add the tool definitions to the AG-UI run input. Commander accepts bounded inline JSON Schema objects as `parameters`.

```js
const tool = {
  name: 'select_document',
  description: 'Choose a planning document from the app',
  parameters: {
    type: 'object',
    properties: { folder: { type: 'string' } },
    required: ['folder'],
    additionalProperties: false,
  },
};

const { unsubscribe } = agent.subscribe({
  async onToolCallEndEvent({ event, toolCallName, toolCallArgs }) {
    const operationId = event.metadata?.commanderOperationId;
    if (!operationId || toolCallName !== tool.name) return;
    const toolCallId = event.toolCallId;
    const content = await selectDocumentOnce(toolCallId, toolCallArgs.folder);
    const response = await connector.submitToolResult({
      operationId,
      message: { id: 'result-' + toolCallId, role: 'tool', toolCallId, content },
    });
    if (!response.ok) throw new Error(`Commander rejected the tool result (${response.status})`);
  },
});
try {
  agent.addMessage({ id: messageId, role: 'user', content: 'Use the app tool to select a planning document.' });
  await agent.runAgent({ runId, tools: [tool], forwardedProps: { generation } });
} finally {
  unsubscribe();
}
```

`selectDocumentOnce` is the embedding app's handler. Key its execution and answer by tool call ID to handle repeated events after reconnect. To report a failed tool, provide the AG-UI tool message's `error` field. A pending invocation times out after one minute. Reconnect with a valid token for the original app and its observe, prompt, and frontend-tool scopes. The renewed token can restore the pending invocation while the same input generation and developer grant remain active. The harness calls the existing worker-scoped MCP bridge. [AG-UI tool lifecycle](https://docs.ag-ui.com/concepts/tools)

Commander saves accepted results before acknowledging them. Later observation of the original operation returns the finished call and result as AG-UI messages, including after a service restart. Retrying the identical tool result recovers its receipt. After a service restart, reconcile an unresolved call in the embedding app before retrying any action that may have had a side effect.

## Open the reference console on a managed worker

Start Commander normally and take input control of a managed worker. Build the browser bundle with `npm run build` from this directory. Then run the connector against that worker and the running service's owner socket.

```sh
AGENT_COMMANDER_SOCKET=/path/to/service.sock node server.mjs --worker WORKER_ID
```

Open the launch URL stored in the private file printed by the command. Use the follow-up field to send a prompt. Tool results expand in the transcript, and a pending request displays a reply field. The displayed harness comes from the worker. The attached console connects to the existing session and closes independently of its worker. The isolated Claude demo remains available by launching without `--worker`.

Reload the same browser tab to reopen its latest submitted run. The tab remembers the run ID and restores the transcript, tool details, and any still-pending request through CopilotKit's connect path. A missing receipt clears the saved run ID and displays an error. This recovery uses the current reference-console launch and tab.

A completed operation shows the available console preview and recorded requests through the end of that turn. If the preview has left the bounded console or Commander restarted a native session's view, the stream shows the gap. Open **Provider history** to inspect what the harness still retains.

`node --test commander-agent.test.mjs attached-console.test.mjs ui/model/contract.test.mjs` exercises the connector and the reference server through CopilotKit against a synthetic worker. The isolated demo uses the same Go message projection, including orphan tool results and failures. A tool disclosure preserves any distinct error alongside its available output. The real-harness acceptance run uses the normal Commander service and the browser workflow above.

## Verified run

Computer Use started a real Claude session with Return, expanded the live `Read` row, and verified that Shift-Return created a second line while the request stayed pending. Return submitted the two-line reply. Claude returned the exact text, including a dollar sign and quotes, and the title bar and footer changed to **completed**. [Waiting for input](verification/terminal-waiting.jpg) · [Completed terminal](verification/terminal-completed.jpg)

In the redesigned footer, **View request** focused the live reply field. I sent the reply and verified that the action and reply shortcuts cleared when Claude finished. [Footer awaiting input](verification/footer-waiting.jpg) · [Footer after completion](verification/footer-completed.jpg)

Assistant output renders a small Markdown subset, including inline code and fenced blocks. Raw tool results remain available inside their disclosure rows. The connector polls the Go snapshot while CopilotKit streams the translated events to the console.
