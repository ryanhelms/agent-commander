# SSH-only continuity verification

The Linux Docker fixture ran native Claude over OpenSSH beside a native Claude worker on the Mac. Both workers used MCP to ask a question and wait for an answer. The same Mac app bundle and identifier were used for the baseline and recovery runs.

| Test | Observed result |
| --- | --- |
| Stop the SSH client for the remote worker on the baseline | The Linux worker failed and its pending question was cancelled. The local worker and its pending question remained active. |
| Stop the same connection with disconnect handling | The worker entered `disconnected` with the same native Claude session ID. The remote request remained pending under its original ID. The local worker stayed active with its own pending request. |
| Suspend the SSH client, accept a synthetic answer through the CLI, then terminate the suspended client | The first reply receipt showed the stored answer as unconfirmed. The disconnect marked its delivery unknown. An identical retry found the existing receipt. The original native transcript could be read through a fresh SSH connection and contained no evidence of delivery. |
| Let the Linux worker receive one answer, then drop its connection while a second question is pending | The coordinator used MCP to confirm receipt of the first answer from the original native conversation. The CLI recovered the same result. The second question kept its original ID and pending status. |

Use `agentctl reconcile REQUEST` or the coordinator's `commander_reconcile_reply` MCP tool to check an ambiguous answer. The shared API operation is `POST /v1/requests/{id}/reconcile`. It checks the original native conversation for a structured result from the matching `commander_wait` invocation. A native result with the exact request ID, worker ID, and recorded answer confirms delivery. An incomplete or inconclusive trace keeps the reply unknown. The check never sends another reply or creates a replacement session.

The existing SSH-only mode can read the original transcript after the transport reconnects. Keeping the in-flight turn across a transport loss still requires persistent host execution. Computer Use verified the retained request and disconnected status on the worker wall, in the focused console, in the pinned side panel, and in the floating PiP window. The remote reply field was disabled and the local worker retained its own reply control. The first build timed out in SwiftUI layout after the drop. The revised Swift build reopened in the same QA bundle and rendered the disconnected state. The visual treatment follows the approved attention controls and uses an amber disconnected label in place of the neutral marker in the concept.
