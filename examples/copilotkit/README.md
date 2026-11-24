# Embed a Commander worker in CopilotKit

This standalone browser app uses the locally packaged `@agent-commander/copilotkit` connector, a CopilotKit 1.90 runtime and the public CopilotKitCore browser client. The browser discovers its worker at `/copilotkit/info` and submits a developer-supplied prompt through the runtime’s agent endpoint. The backend uses the connector to answer a specific pending request and retrieve the original tool output.

## Run it

Use Node 22 or newer. From the Commander checkout, copy the example and local release into an independent directory. With the supplied lockfile, npm verifies the connector tarball and its dependencies.

```sh
example_dir=$(mktemp -d)
cp -R examples/copilotkit/. "$example_dir/"
cp dist/copilotkit/agent-commander-copilotkit-0.1.6.tgz "$example_dir/"
(cd "$example_dir" && npm ci --ignore-scripts && npm run build)
```

Take input control of a test worker in Commander. Supply its worker ID and the path to the owner socket, then open the local URL printed by the app. The URL contains the private session token.

```sh
(cd "$example_dir" && AGENT_COMMANDER_SOCKET="$OWNER_SOCKET" npm start -- --worker "$WORKER_ID")
```

If the stream closes before Commander confirms the outcome, choose **Reconnect to this run**. The tab keeps the original run ID through reload. Reconnect performs a passive lookup of the same operation and can recover after the app regains its grant.

Enter your own prompt. To exercise the complete workflow with a held Claude or Codex worker, use this prompt.

> Call commander_ask with exactly this question: "Which code confirms ASK-TOOL-RECEIPT?" Call commander_wait with the returned question ID. Reply with my exact answer after it arrives.

1. Select **Send**. When the question appears, enter `LAPIS-742` and select **Answer**. The app sends the displayed question's request ID, the held input generation, and your answer.
2. Expand **Tool result** for the call that contains `ASK-TOOL-RECEIPT`. Select **Open original ACP result**. The app follows that message's operation and cursor to the original provider data.
3. Check the assistant's response for `LAPIS-742`. **Open provider history** also works for a bound stopped worker whose harness supports history.

For an archived Claude or Codex image, choose **Open provider history**, expand the **user message** that carried the attachment, then choose **Open attachments** and the individual item. An archived user message received in the AG-UI conversation has the same control. Inline images open in place and inline audio has playback controls. Remote URLs and file paths appear as text. The backend fetches the selected original by its message cursor. [Verified archive workflow](../../design/verification/copilotkit-live/README.md#opening-archived-prompt-attachments)

To run the same browser workflow without a provider account, use the repository's disposable stdio fixture from the Commander checkout.

```sh
python3 design/verification/copilotkit-live/independent-fixture.py --agentctl dist/agentctl --app "$example_dir"
```

Stop the example with Ctrl-C. The fixture runner closes its own service and worker.

## Integration points

The backend creates one connector for the selected worker, registers `worker.agent` with `CopilotRuntime`, and serves the runtime at `/copilotkit`. The browser uses `CopilotKitCore.getAgent` and `runAgent`. The runtime consumes the example's bearer token locally and excludes it from headers forwarded to the owner socket. A local reply route calls `worker.reply`, and the source route calls `worker.readHistory`. Both retain the backend's worker binding. No imports reference the Commander checkout. [Backend](run.mjs) · [Browser client](client.mjs)
