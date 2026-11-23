# Console shell and Needs Attention review

These are Computer Use captures of the rebuilt macOS app with sample activity paused.

| View | Native capture | Visible change |
| --- | --- | --- |
| Coordinator and workers | [Coordinator wall](coordinator-wall.jpg) | Slim terminal title bars and square pane edges. Each worker title bar keeps its host and branch together and aligns scrollback across the row. |
| Focused worker | [Focused worker](focused-worker.jpg) | A single console title bar includes the worker lineage and Linux SSH host. |
| Picture-in-picture | [Reply](attention-pip.jpg) · [Incoming request](pip-arrival.jpg) | The inner console is square. The outer floating stack keeps its glass treatment. The selected worker shows keyboard focus in its footer. |
| Remote Mac | [Event schema wall](remote-mac.jpg) | The Schema migration worker shows the Mac platform mark and host `lab-02`. Its accessible title identifies macOS over SSH. |
| Needs Attention | [Pinned, the default](attention-panel.jpg) · [Unpinned overlay](attention-overlay.jpg) | Pinning reserves space beside the wall or focused worker. The unpinned panel sits over the full-width worker area. |

The coordinator, worker wall, focused worker and PiP share `ConsoleTitleBar` and `ConsoleSurface`. The platform cue comes from typed execution-host metadata. The local service's `localhost` marker maps to this Mac. Known remote platforms in the previews use explicit fixture data. Hosts whose platform is unavailable use neutral chrome. [Component map](../../system/ATOMIC-DESIGN.md) · [Prior console review](../terminal-cockpit/README.md)

Computer Use verified that pinning preserves the active request, reply draft and keyboard focus. Closing the panel and invoking Next request reopened the draft. Focusing another worker left the sidebar visible. The app stores the live presentation and pin setting locally. [Original side-panel concept](../../concepts/attention-panel.png)
