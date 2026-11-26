# Agent Commander MVP

Agent Commander is a macOS desktop app for supervising coding agents running in tmux on a Mac and enrolled SSH hosts. Its first user is a developer who normally runs one to three coordinators, each directing up to ten workers. The developer should be able to ask for a feature plan in their usual client, watch the work unfold, and answer the one question that truly needs them.

## Fastest path to a usable build

The coordinator wall and picture-in-picture direction are approved. Build one real local workflow end to end. Open a directory, give a coordinator a planning task, and let it launch two managed workers through MCP. Show their live tmux consoles beside the coordinator. Have one worker ask a question, answer it in PiP, and see the answer in that worker’s conversation while the other keeps running. Expose the same run through a thin CLI command that calls the API. Use this build on a real task as soon as that works.

The local Claude Code workflow and native design gallery are implemented. Introduce the Go package from the shared harness SDK during the local ACP and native-history migration. Exercise Claude and Codex through the same caller before extending it to SSH. Use the [approved screen concepts](design/concepts/index.html) and the existing black-glass components.

Start with managed Claude Code workers on the developer’s Mac. Try a worker question that blocks its current task, then reply with multiline text containing shell punctuation. Watch that same worker resume and use the answer in its next action. A service receipt alone leaves the worker’s progress unverified. Keep the provider choice behind the existing adapter so this exercise transfers to Codex. [Claude Code CLI reference](https://code.claude.com/docs/en/cli-reference)

## Native preview pass

Build the screens in SwiftUI, using the same Atomic Design components and layouts as the live cockpit. Use changing sample data to show representative work across hosts, workers and runs. Keep sample interactions inside the preview, including filters, selections, dialogs, and navigation across screens. The five existing design previews are the starting point. Provide a way to browse all the states inside one preview window and preserve direct launch by scenario.

| Workflow | Remaining views and states |
| --- | --- |
| Supervise work | Worker actions, attention queue, attention side panel, and switching to another run with a pending request. |
| Navigate the workspace | All agents, project overview, smart views, and linking checkouts. |
| Delegate and review | Worker delegation, successful and blocked integrations, searchable run history, and cross-run questions. |
| Set up and recover | First run, hosts and capabilities, clients and MCP, session adoption, reconnect, provider sign-in, and preferences. |
| Use accessibility settings | Reduced-transparency preferences, worker wall with PiP, and focused-worker control. |

Claude Opus owns the Swift implementation. Codex checks the native previews through Computer Use and compares them with the corresponding concept frames. Review the UI in the running app, then connect each workflow to the shared API in the delivery order below.

## First-run experience

1. Open a project directory. Discover local clients and tmux sessions. Enroll SSH hosts using the developer’s SSH configuration. Show what each host supports. A reusable launch profile supplies an executable and arguments for clients discovery misses.
2. Connect the Commander MCP server to a client. Where the client supports it, configure its delegation tools and standing project instructions once so managed coordinators delegate through Commander. Apply the same setup to workers that can delegate. Let the developer set allowed clients, models, hosts, and a worker limit for the run, including nested workers.
3. Start or resume a coordinator in Commander or in the usual client. Both entry points show the same run. The coordinator chooses workers within the configured limits. Workers can ask questions, request approvals, and return results to their parent.
4. The coordinator handles routine decisions. When it needs the developer, show the question, the worker’s assignment, the host, and the decision that is blocking progress. Open the exact pending request or live prompt.

## The cockpit

Agent Commander owns its design system locally. Keep its components, tokens, artwork and release history inside this project. Use the [interface system](design/system/DESIGN-SYSTEM.md) and [Atomic Design analysis](design/system/ATOMIC-DESIGN.md) to implement the cockpit and its companion views.

| View | Behavior |
| --- | --- |
| All agents | Watch live consoles across projects and enrolled hosts. Filter by project, coordinator run, host, client, worktree, directory, or attention state. Save a combination of filters as a smart view. |
| Project | Opening a directory shows its coordinators. Include subdirectories, linked Git worktrees, and remote checkouts when repository identity can be verified. Show host and worktree on each tile. Offer explicit linking for ambiguous copies. A directory without Git is still a project. |
| Coordinator | The coordinator’s live console occupies the left third by default. A draggable divider resizes it. The right side is a horizontally scrollable, multi-row wall of live workers. Nested workers stay under their parent in collapsible groups. |
| Focused worker | Zoom one worker to fill the right side. Keep the coordinator visible. Returning restores the wall’s position, collapsed groups, and keyboard focus. |
| Needs attention | Stack picture-in-picture terminals in the bottom-right corner of the worker area. Reply in place or expand a terminal. The stack identifies the worker and run even when a different run is open. Also support a global queue, side panel, or switching to the blocked run as selectable presentation preferences. |

Every delegated task gets its own controllable tile, including a task delegated by a worker. Allocate its assignment ID before launch and bind the tile to the worker’s control endpoint when ready. From that tile, the developer can read the assignment, send a follow-up, answer a pending question, interrupt, or stop that worker independently. Retrying a launch or reconnecting to a host restores the same tile.

Watching a tile is passive. Taking input acquires exclusive Commander control of that worker until the developer explicitly hands it back. Zooming out, closing a PiP, or reconnecting preserves ownership. An inline answer applies to one request ID. A second answer to a resolved request shows its resolution. Other workers continue. External terminal users retain ordinary tmux access, so the exclusivity guarantee applies to input routed through Commander.

Give attention, connection, and task state separate indicators. A silent but connected worker, a worker awaiting a decision, and an unreachable host require different actions. Support keyboard navigation between the coordinator, next pending question, focused worker, and previous view.

## Conversations and providers

The unit of coordination is a **conversation**. It has a stable Commander ID and can have a provider session ID, a tmux pane, a current assignment, and an owner. Store run and parent IDs at delegation time. Moving a pane, changing directory, or changing a smart-view filter preserves lineage. Key a terminal by host and tmux server instance as well as pane ID. Similar paths and titles alone cannot establish identity.

An agent uses domain operations such as delegate, send a message, wait for a reply, answer a pending request, and return a result. Each message has a recipient, message ID, and optional reply-to ID. Store message content as data all the way to the receiver. Pass launch arguments separately from prompt text. A literal dollar sign, backtick, newline, or code fence must reach the worker unchanged.

| Client capability | MVP contract |
| --- | --- |
| Any MCP-capable client | Can register, coordinate a run, delegate, read an inbox, reply, and report its own state, questions, and results through the same documented tools. Offer bounded waits with a cursor. An interactive client must call the tool to receive inbox messages unless it has a supported wake-up mechanism. |
| Managed worker | The tmux pane can host Commander’s interactive conversation UI. A developer attaching from an ordinary terminal sees prompts, streamed responses, and approvals, and can take control through the same API. A launch profile describes how to start an unfamiliar executable. A provider advertises which structured operations it supports. |
| Existing Claude or Codex session | Discover automatically and associate with its live provider conversation. Prefer a supported live connection. Automatic handoff is allowed when idle and Commander can verify history and pending work are preserved. Add full conversation and approval controls as each adapter proves it can preserve the session. If identity or preservation is uncertain, keep the pane live, expose the reason, and offer the supported recovery action. |
| Other existing terminal | Discover and show its actual console. Enable conversation controls as the client registers or its adapter verifies support. Human terminal interaction remains available. Provider-owned approval dialogs require a provider hook, an explicit report, or human interaction at the prompt. |

Prefer Commander’s MCP delegation tool when a client also offers internal subagents. It launches an independently addressable worker even for a short research task. During setup, show whether the client lets Commander route all delegation this way. A client that exposes only a summary of an internal task can still include it in the parent transcript. Creating a controllable worker for that assignment requires routing its launch through Commander or a provider integration with independently verified controls.

Track acceptance by Commander, delivery evidence from the worker or provider, and completion separately. Deduplicate retries by request ID. After an ambiguous disconnect, reconcile against the worker’s inbox or the provider’s pending request. If the outcome is still unknown, surface that uncertainty and retain the original message. Automatic replay is appropriate only when duplicate effects can be ruled out.

Use ACP as the default provider connection. Prefer a harness’s native ACP endpoint when available and evaluate the upstream Claude and Codex adapters against stable ACP v1. Keep the API for Commands and AG-UI for the desktop and terminal clients’ view of the conversation. Use tmux to host or attach to the managed conversation and discover existing panes. Use capability checks for prompt, cancellation, approvals, history replay and reconnect. An unavailable structured operation uses the standard exception path. Prove live delivery and history reload on local Claude and Codex before expanding to SSH. For adoption, verify provider session identity and preservation of pending work before transferring control. [ACP session setup](https://agentclientprotocol.com/protocol/v1/session-setup) · [Claude adapter](https://github.com/agentclientprotocol/claude-agent-acp) · [Codex adapter](https://github.com/agentclientprotocol/codex-acp)

### Common harness SDK

Build `agent-acp` in its own repository. Generate the Go, TypeScript and Python session clients from a single versioned Protobuf schema. Each language has its own package and uses the same conformance fixtures. Agent Commander consumes the Go package, `agentacp`. The SDK exposes portable session handles, events and capabilities. Commander selects the harness and execution host under its run policy and maps its worker IDs to SDK sessions. Other consumers can use their own identities and authorization policies.

| Caller intent | SDK contract |
| --- | --- |
| Work with a live session | Open or resume a conversation, send a literal message, observe typed events, answer an outstanding request by ID, and interrupt the current turn. Surface message, tool activity, input request and turn outcome consistently. |
| Inspect history | List conversations in scope and read their history in pages with opaque cursors. The adapter uses ACP replay when it can do so passively, or the provider’s native reader. Opening history must preserve active input ownership. Historical approvals are display-only. |
| Handle differences | Report capabilities in user terms, such as interrupting a turn or answering an approval. Provide the same typed outcomes for an unsupported operation or uncertain delivery across providers. |

ACP method names, wire events, native pagination and CLI invocation stay inside SDK adapters. The service authorizes each action and translates the SDK’s events to AG-UI for the cockpit. MCP, CLI and desktop callers continue to use the same service API. tmux remains responsible for hosting and attaching to a process. The SDK reads conversation history from the harness and keeps only the bounded in-memory projection needed by its callers.

Develop Commander and the SDK’s Go module under `sdks/go` side by side using a local Go workspace. Exercise one SDK example against both Claude and Codex, including a prompt, a request and reply, a targeted interrupt, and a history read after reconnect. Release the language packages from the SDK repository. Each consumer pins the package version it uses.

## API and runtime

The macOS app, terminal UI, and CLI call one versioned API. An agent calls MCP, and the MCP server calls that same API for every domain operation. The API owns validation, permissions, operation status, provider selection, state changes, and event subscriptions. Local connections and SSH tunnels serve one user in the MVP. Each coordinator receives a scoped run identity. CI credentials and separate team identities are later milestones.

For the first production harness release, a developer can also grant a hosted CopilotKit app scoped access through direct HTTPS or an outbound relay. Commander enforces the same worker ownership and request semantics through either route. The integration plan defines the embeddable client, relay editions, verified adapter catalogs and release gates. [Harness integration plan](design/HARNESS-INTEGRATION-PLAN.md)

| API area | Operations shared by the applicable interfaces |
| --- | --- |
| Project and host | Open project, list and link checkouts, enroll host, discover clients and panes, inspect capabilities, configure limits and retention. |
| Run and worker | Register or resume coordinator, delegate with a host and workspace choice, discover or adopt worker, inspect lineage and starting snapshot, request status, interrupt, stop, archive. |
| Conversation | Send, receive or wait, reply, report result, escalate, resolve approval, take or release control. |
| Observation | Subscribe to a live console or run events, restore a snapshot after reconnect, query history, search transcripts, list pending decisions. |
| Integration | Prepare candidate revision, integrate worker changes, run combined tests, inspect conflicts and results. |

The desktop service stays up when its window closes. A host with a persistent user-level helper can keep local coordination, replies, and pending decisions available during an SSH outage. On a host allowing only SSH, use tmux through the connection. Surviving processes can continue within their existing capabilities. The client shows which decisions require reconnection and which history intervals it could recover.

Each run chooses its disconnect behavior. A remote coordinator with the necessary local service and dependencies can keep delegating within its limits. Another run can finish current assignments and hold further delegation for reconnect. Validate the chosen behavior against the coordinator’s host and reachable workers at launch. If an approved host disconnects mid-run, show the affected workers and keep unrelated ones active. Restore live panes from snapshots and replay durable events from a cursor.

**Standard exception path.** A request returns a result or an operation ID with a typed outcome such as `requires_user_action`, `unsupported_capability`, or `delivery_unknown`. Include the affected worker, the reason, any safe continuation, and the status lookup. For example, a sign-in request opens the provider’s prompt for the developer. The originating MCP client can await the same operation and continue after verification. A local bootstrap or service-recovery action may start the API process itself. Domain mutations then go through the recovered API.

**Control boundary.** The owning coordinator directs, approves, interrupts, or stops its worker within the developer’s policy. Other coordinators in the project can read transcripts and results and ask the owner questions. A question goes to the owning coordinator’s inbox. A change to a worker requires a separate command from an authorized actor. Validate ownership and current input control again when a queued command executes. These are Commander permissions within the developer’s existing user account.

Bind each managed MCP connection to its run and actor when launching or enrolling the agent. Derive the caller from that binding. Treat worker and request IDs supplied in a tool call as targets. This lets two coordinators use the same MCP tool configuration while keeping control scoped to their own workers.

**Stop run.** Closing a window leaves the run available to reattach. An explicit stop first closes delegation for that run, including nested launches, then requests cancellation of its managed work. Show which workers stopped and which are still awaiting confirmation. Leave unrelated tmux sessions and on-disk work intact. If the service restarts mid-stop, reconcile the original operation before acting again.

**Launch from Finder.** During setup, resolve the local provider and tmux executables to full paths and save those paths in the host profile. Exercise the first build from Finder as well as a development shell. If an executable moves, show which path needs updating.

## Workspaces, integration, and history

Research and review can share the coordinator’s checkout. Give each coding worker a separate branch and linked worktree on the selected host. Create it with `git worktree add` and a full destination under `~/.worktrees/<repo-name>/<worktree-name>/`. Derive the repository name from its origin URL, falling back to the primary checkout directory name. Use a single directory component for the worktree name. Use `git worktree move` for relocation and verify the registered path with `git worktree list`.

**Starting from uncommitted work is a per-assignment choice.** Expose the same choices in the cockpit and the delegation API used by MCP and the CLI. The coordinator may choose within the developer’s limits. If the assignment requires a choice it cannot resolve, surface that specific decision in the cockpit.

| Assignment choice | What the coding worker receives |
| --- | --- |
| Start from a commit | Create its worktree at the recorded commit on the selected host. The developer’s working edits stay at the source. |
| Include working changes | Start at the recorded commit and apply a snapshot of selected edits or all tracked edits. Include untracked files only when explicitly selected. Show the destination host and included paths. |
| Keep the work on the source host | Create a separate local worktree and bring in the edits the assignment needs. Moving this assignment or its edits to another host requires a new placement decision. |

Record the base revision, snapshot identity, included paths, and destination with the assignment. Preserve the source checkout and index while capturing it. Verify the worker’s starting state before launching the task. Report worker-authored changes against that starting state so inherited edits remain distinguishable during integration.

Each handoff contains findings, changed revision or diff, and test commands and outcomes. The integration operation gathers the selected worker changes on the coordinator’s host, records the base revision, builds a candidate in a disposable worktree, and runs the project’s combined tests there. Before advancing the target branch, verify that its expected revision and checkout state still permit the update. Conflicts, test failures, missing tests, and concurrent changes get explicit outcomes. The coordinator can resolve or retry within its limits. Retain worker branches and evidence of failed attempts. A successful result names the tested revision and the target branch that received it.

Use harness-owned transcripts as the source of conversation history. Persist Commander’s task tree, provider session references, approval outcomes, assignment results and delivery receipts. Use ACP replay where supported, then provider-native read APIs for history that requires separate lookup or pagination. Search on demand within the selected project and date range, and associate results with their run, worker, host and native transcript position. Keep live projections in bounded memory. The harness controls transcript retention. Commander can configure retention for its own run metadata and show when a source session has expired, a host is offline, or part of the live console was never retained by the harness.

## Patterns with specific jobs

| Pattern | Design decision |
| --- | --- |
| GoF Adapter | A tmux adapter handles terminal streams. Separate client adapters handle provider conversations, approvals, discovery, and capability checks. Each can be exercised independently. |
| GoF Strategy | Select an identity-resolution strategy when Git evidence and explicit checkout links require different algorithms. Simple metadata filters and capability choices can use ordinary predicates. |
| GoF Command | Represent actions such as delegate, answer, interrupt, and integrate as explicit requests with an actor, target, preconditions, and observable outcome. |
| EIP Request-Reply and Correlation Identifier | Tie a worker answer or approval to the exact outstanding request, including through reconnects and concurrent turns. [Correlation Identifier](https://www.enterpriseintegrationpatterns.com/patterns/messaging/CorrelationIdentifier.html) |
| EIP Idempotent Receiver | Repeated delegates and answers return the original outcome or enter reconciliation if delivery is uncertain. [Idempotent Receiver](https://www.enterpriseintegrationpatterns.com/patterns/messaging/IdempotentReceiver.html) |
| EIP Publish-Subscribe Channel | The wall, PiP, CLI, and coordinator can observe a shared stream of run events. Use separate terminal-output subscriptions so a noisy pane cannot delay an approval. [Publish-Subscribe Channel](https://www.enterpriseintegrationpatterns.com/patterns/messaging/PublishSubscribeChannel.html) |
| EIP Process Manager | Use checkpoints for a fixed handoff. Use a Process Manager when Git integration or adoption must wait on other participants, branch on their responses, and resume after interruption. [Process Manager](https://www.enterpriseintegrationpatterns.com/patterns/messaging/ProcessManager.html) |

The selected implementation uses SwiftUI and AppKit in Swift for a macOS 26+ cockpit, and Go for the API service, CLI, MCP adapter and host helper. Build from source first, then distribute a signed, notarized download. Exercise Linux and remote macOS hosts. Keep provider contracts versioned and publish a small conformance suite. Prototype the renderer, provider adoption, search over harness-owned transcripts and SSH data path. See the [technology decision](design/TECHNOLOGY.md).

Before coding a slice, consult the [existing pattern analysis](design/PATTERN-DECISIONS.md). Reuse its decision when it fits. A new or changed boundary only needs a short note on the choice and the problem it solves. Choose the simplest implementation that preserves the behavior.

## Delivery order

| Increment | First usable behavior | Extend it during subsequent use |
| --- | --- | --- |
| M1 · Local conversation | One managed worker receives a literal multiline prompt and returns a named question through MCP and the shared API. | Add adapters and existing-session adoption as each provider supports verified handoff. |
| M2 · Local cockpit | Put a coordinator and two live workers on screen. Answer in PiP, return to the original view, and inspect the run from the CLI. This is the first personal-use build. | Add nested delegation, worker zoom, input takeover and handback. Preserve the current input target and deduplicate a repeated reply from the first version that sends input. |
| M3 · Project wall and first SSH host | Connect a real SSH host, show host and worktree on the tiles, and group local and remote workers by run or project. | Add saved views, collapsible groups, and tune the wall with the user’s one-to-three coordinator workload. |
| M4 · Remote continuity and permissions | Use the remote host during an actual task. Honor run policy and ownership, show disconnects, and reconcile outstanding requests before retrying. | Exercise persistent helpers and SSH-only hosts across Linux and macOS, including Mac sleep, cross-run questions, and affected-worker recovery. Run the Commander service headless on a Linux server, and deploy, upgrade or roll back any GitHub release of it from Agent Commander or with a one-line install. [Headless Commander](design/HEADLESS-COMMANDER.md) |
| M5 · Coding, integration and recall | Give each coding worker its own worktree, return its changes and test results, integrate a candidate and run the combined tests. Make a finished run searchable. | Add the per-assignment uncommitted-work choices, conflicts, moving target branches, transcript gap display, and configurable retention. |
| M6 · Additional clients | Connect an unfamiliar MCP-capable client and exchange an assignment, a question and a result. | Add discovery profiles and document capability-specific extensions discovered through use. |

The milestones describe an implementation sequence. Work can overlap when a real run needs it. Run a short smoke check on the behavior being added. Target identity, permission checks and honest delivery status belong to each operation from its first use. Expanded fixture coverage, performance measurements, notarization and catalog polish can proceed as those needs arise.
