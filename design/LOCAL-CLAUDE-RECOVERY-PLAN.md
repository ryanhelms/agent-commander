# Local Claude operator recovery plan

The quiet-worker change shows the last Claude ACP update and its age on the wall and in focus. **Inspect source** is available when the cockpit lacks fresh progress evidence. The isolated review still reproduced all five recovery gaps below. The changes apply to locally managed Claude ACP workers and use the existing worker, request, session, turn and operation identities.

## 1. Show when a completed worker’s provider has exited

Record provider availability separately from the completed turn outcome. The original runner reports a confirmed adapter exit. The service rejects new follow-ups for a worker whose provider is gone and resolves any follow-up it can prove was still unclaimed. Preserve an uncertain outcome for operations that may already have reached Claude. The cockpit explains the exit and offers the existing read-only source inspector.

Verify with a worker that completes a turn and then loses only its adapter. Its completed outcome remains visible, the next follow-up receives a clear refusal, any unclaimed receipt resolves, and a sibling still accepts work. [ACP lifecycle](../internal/provider/acp.go) · [Worker control](../internal/service/control.go)

## 2. Recover a surviving turn after the service restarts

Build on the provider availability model from item 1. Let the original authenticated runner report its bound session and current turn when it reconnects. Reconcile only matching worker, session and turn identities. While the service is checking, surface the restart reason beside the existing **Watch Terminal in Window…** and **Inspect source** actions. Enable targeted control once the original turn and input authority are confirmed.

Verify by restarting only the isolated service during a silent Claude turn. The original adapter and assignment survive. The cockpit regains eligible control before another Claude update arrives. Also run an absent-runner case and confirm that it remains unresolved without sending a prompt. [Service startup](../internal/service/api.go) · [Native terminal actions](../Sources/AgentCommander/NativeTerminalComponents.swift)

## 3. Show what happened to an interrupt

Extend the existing interrupt state with evidence for service acceptance, notification sent, and observed turn end. Keep the status tied to the original turn and input authority. When the outcome is unknown, show the last confirmed step and offer read-only inspection. Keep stopping the worker an explicit operator choice.

Verify with two ACP cases. A peer that receives cancellation and ends the turn produces a confirmed outcome. A peer that receives cancellation and stays open shows the sent notification and unresolved outcome. Repeated requests and a cockpit reconnect preserve the original operation. [Interrupt handling](../internal/service/control.go) · [ACP cancellation](../internal/provider/acp.go)

## 4. Keep queued follow-ups visible through their outcome

Reuse the existing follow-up receipt in the focused cockpit. Show what the message is waiting for, retain an outcome after the count drops, and distinguish a runner claim from provider delivery. Explain beside **Hand back** when it will cancel an unclaimed message. Use the request navigation from item 5 when an addressed approval is the current blocker.

Verify with a queued follow-up behind a pending approval. In one run the operator answers and the existing turn ends, then the same follow-up is submitted once. In another run the operator hands back control, the receipt remains visible as cancelled, and the peer receives no follow-up. Check a reconnect in each case. [Follow-up lifecycle](../internal/service/control.go) · [Focused footer](../Sources/AgentCommander/Organisms.swift)

## 5. Make every pending approval reachable

Project the Attention queue by request ID. Keep one inline form per worker for the existing compact layout. Count and navigate all pending requests in Attention, including additional requests from the currently focused worker. Use the existing exact choice buttons wherever the selected permission request is answered.

Verify by opening two approvals for the same worker before answering either. The badge counts both and Next Request reaches both. Resolve one by its original ID, reconnect, and confirm the other remains pending and actionable. [Request projection](../Sources/AgentCommander/Components.swift) · [Attention navigation](../Sources/AgentCommander/CockpitView.swift)

## Delivery order

Start with confirmed provider exit, then reuse that contract for restart reconciliation. The interrupt receipt and full Attention queue can each proceed independently of provider availability. Land interrupt status and request navigation before wiring the follow-up explanation so the focused view can use consistent receipt language and link the original blocker. Coordinate changes to the shared Swift cockpit components as those slices land.
