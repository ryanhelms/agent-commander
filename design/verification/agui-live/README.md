# Live AG-UI cockpit verification

The captures come from a signed local build connected to an isolated Go service and real Claude Code sessions in tmux.

| Area | Native capture | Observation |
| --- | --- | --- |
| Coordinator and worker wall | [Two-worker run](live-wall.jpg) | The coordinator and two MCP-managed workers received structured output live. Expanding the coordinator's Read row showed the tool result. |
| Focused worker | [Rollout](live-focused.jpg) | The focused console used the same transcript and single-line title bar as the worker wall. |
| Visible waiting worker | [Header check](live-foreground.jpg) | The console itself indicated the pending request. View request remained available without an automatic duplicate sidebar. |
| Floating PiP | [Live request](live-pip.jpg) | A separate native panel opened the exact pending request. It could be dragged and stored its position across launches. |
| Run completion | [Resolved request](live-final.jpg) | The worker received its answer and reported it through MCP. Both verification sessions with a single worker and the run with two workers completed. |

The profiler reproduced the original freeze with a request pending. The main thread repeatedly re-entered AppKit layout through `NSHostingView.updateAnimatedWindowSize` while the AG-UI reader waited for data. The fix bounds the `NSPanel` size, disables hosting-controller window sizing and scrolls long content inside the panel. In a follow-up sample with PiP open, the main thread spent 84% of samples waiting for events and showed no recursive window-sizing frames. [Fixed window host](../../../Sources/AgentCommander/FloatingAttentionPanel.swift)

The live test used a separate data directory, and the app preferences used for the test were restored afterward. The regular service was idle when it was restarted with the update. Its AG-UI endpoint returned HTTP 200, and the regular cockpit reopened online.

## Floating PiP persistence

The final signed build kept the same window at the same bounds through Commander → Calculator → Commander. macOS confirmed that Calculator was the foreground app and that PiP was above its window. A separate native AppKit regression test minimized the main window with a request already pending, then confirmed the same PiP window remained on screen after the Dock animation. Dragging the title bar moved its on-screen origin from `(1315, 182)` to `(1215, 136)`. A new Commander process restored the exact `(1215, 136)` origin and window size.

Fable added a native drag handle over the non-interactive title area and saves its location when a drag ends. Commander also reorders an eligible existing PiP after minimize and activation transitions. Both changes use the existing fixed-size panel.
