# Focused Pretty console review

The **Retry policy review** worker is open in Pretty in the primary macOS app. This review uses a scripted local ACP peer with real JSON-RPC traffic through Commander. The focused console reads the worker’s structured AG-UI projection. Its native SwiftUI approval controls follow the CopilotKit reference and use the existing request and input ownership paths. [Focused composition](../../Sources/AgentCommander/FocusedPrettyConsole.swift)

Computer Use expanded the **Inspect retry policy** disclosure and displayed the retained result. Clicking **Run once** sent the exact offered choice to the original ACP peer. The original tool update contained the matching completion marker and the expanded tool showed three passing checks. Taking control and submitting a follow-up streamed a second response into the same conversation.

The focused layout keeps the coordinator on the left, reuses the console title bar, and places the structured conversation and its approval form in the worker pane. While the top bar correctly showed **Waiting for you**, the existing tool row labeled the approval-gated tool **running** until its result arrived. [Focused worker concept](../concepts/focused-worker.png)

## ACP thinking and usage

A second local ACP peer emitted two thinking chunks with one message ID. The managed runner printed the thinking in its tmux pane. The scoped AG-UI worker snapshot carried both chunks and the latest readings while the worker remained active. After the follow-up, context was 13,600 of 200,000 tokens. The latest reported token counts were 2,300 input, 390 output, 80 thinking, and 1,200 cache read, with the supplied total of 2,690. Each value came directly from its respective ACP update or prompt result.

After reopening the primary app, Computer Use verified both modes on the same focused worker. Terminal showed both thinking chunks as lines in the tmux output. Pretty combined them in one expandable Thinking section. Both footers displayed 7% context use, 2.3k input tokens, and 390 output tokens. The footer accessibility value exposed the full reported counts. The focused Pretty console stayed open with Thinking expanded for review.

The narrow coordinator Terminal pane showed clipped tmux output in the same layout. The focused worker had enough width to read both thinking lines and its usage footer.

## Cockpit rollout

The coordinator, wall, focused worker and PiP use the shared Pretty ACP console. The rollout fixture uses live JSON-RPC from scripted ACP peers in two runs. On the foreground run, Terminal showed the coordinator and workers' thinking lines. Pretty opened the coordinator and wall worker's full thinking text in their own disclosures. Both views reported 18,600 of 200,000 context tokens and 3,100 input / 620 output for the coordinator, and 13,200 of 200,000 context tokens and 2,300 input / 390 output for the Retry boundary worker.

The background worker reached the floating PiP while the foreground run stayed selected. The PiP displayed the same 13,600 of 200,000 context tokens and 2,300 input / 390 output in Terminal and Pretty. Pretty expanded the worker's thinking and offered the exact ACP approval choices. The Run once button delivered `run-once` to that worker's original request and cleared the card. The foreground run recorded no request or reply.

The floating panel reopened at its saved 747 × 458 point content size. The Computer Use captures before and after the restart had identical window dimensions. Computer Use could see the resize handle, but its synthetic drag did not change the window size on this desktop.

Terminal PiP displayed the approval worker's raw tmux thinking and the provider usage footer. Pretty PiP displayed its expandable Thinking entry, a short amber Approval activity line, and one live form with Run once and Skip. The same renderer showed inline Context and Turn ended activity on the coordinator and wall.

In the follow-up review, the coordinator, workers, and PiP opened in Pretty by default. The pending request carried the unresolved tool's ID from the full available worker transcript into PiP. Computer Use saw **Awaiting approval** on the tool row and in its accessibility label. The original scripted request stayed open and unanswered.
