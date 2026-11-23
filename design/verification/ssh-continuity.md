# SSH-only continuity verification

The Linux Docker fixture ran native Claude over OpenSSH beside a native Claude worker on the Mac. Both workers used MCP to ask a question and wait for an answer. The same Mac app bundle and identifier were used for the baseline and recovery runs.

| Test | Observed result |
| --- | --- |
| Stop the SSH client for the remote worker on the baseline | The Linux worker failed and its pending question was cancelled. The local worker and its pending question remained active. |
| Stop the same connection with disconnect handling | The worker entered `disconnected` with the same native Claude session ID. The remote request remained pending under its original ID. The local worker stayed active with its own pending request. |
| Suspend the SSH client, accept a synthetic answer through the CLI, then terminate the suspended client | The first reply receipt showed the stored answer as unconfirmed. The disconnect marked its delivery unknown. An identical retry found the existing receipt. The original native transcript could be read through a fresh SSH connection and contained no evidence of delivery. |
| Let the Linux worker receive one answer, then drop its connection while a second question is pending | The coordinator used MCP to confirm receipt of the first answer from the original native conversation. The CLI recovered the same result. The second question kept its original ID and pending status. |

Use `agentctl reconcile REQUEST` or the coordinator's `commander_reconcile_reply` MCP tool to check an ambiguous answer. The shared API operation is `POST /v1/requests/{id}/reconcile`. It checks the original native conversation for a structured result from the matching `commander_wait` invocation. A native result with the exact request ID, worker ID, and recorded answer confirms delivery. An incomplete or inconclusive trace keeps the reply unknown. The check never sends another reply or creates a replacement session.

| Mode | What recovers |
| --- | --- |
| SSH-only | Commander retains pending questions and native history references. A fresh SSH connection can inspect original delivery evidence. The disconnected adapter turn ends. |
| Persistent SSH | The host keeps the adapter alive while the controller reconnects. The original turn can consume its original pending reply. The local controller and host process both need to survive. |

On the authenticated Linux fixture, both workers were pending before the fault. Terminating only the persistent worker's SSH process changed that worker's connection to reconnecting. Commander retained both question IDs and the remote native session ID. A replacement SSH process reattached. A reply through the CLI and its identical retry returned the same receipt. The original remote turn reported the answer, and its native history remained accessible through the same session reference. The local worker and its pending question stayed active.

For the cockpit test, a loopback proxy held only the QA worker's replacement connection. The wall displayed the host as reconnecting beside its pending request. In PiP, the same request accepted an answer and explained that Commander would hold it. The API still showed the host as reconnecting when it stored the answer. After the proxy reopened, the original native turn reported that answer. Computer Use used the same single QA app and bundle identifier.

An explicit stop removed the persistent worker's host-side directory and helper. The local worker's question remained pending.

Select the opt-in mode with `AGENT_COMMANDER_SSH_MODE=persistent` on the Commander service; the enrolled host must point `AGENT_COMMANDER_SSH_AGENTCTL` at an agentctl build with the persistent helper. Omit the mode or use `ssh-only` for the direct adapter path. The persistent helper is installed under the SSH login. It needs no inbound service, custom transcript database, or separate harness credentials.

Computer Use verified the SSH-only retained request and disconnected status on the worker wall, in the focused console, in the pinned side panel, and in the floating PiP window. The remote reply field was disabled and the local worker retained its own reply control. The first build timed out in SwiftUI layout after the drop. The revised Swift build reopened in the same QA bundle and rendered the disconnected state. The visual treatment follows the approved attention controls and uses an amber disconnected label in place of the neutral marker in the concept.
