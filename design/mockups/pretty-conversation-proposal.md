# Pretty as a conversation: proposal

Status: **decisions taken on 2026-11-26** (below). No app code or token change has been made. `DESIGN.md` and the related rules are being updated to allow this design.

| Part | Where |
|---|---|
| Current vs proposed mockup | [pretty-conversation.html](pretty-conversation.html) |
| Every tool's wording, grouping rules, components | [pretty-conversation.md](pretty-conversation.md) |
| CopilotKit, scope, phases, questions | This file |

## Scope: the whole Pretty view; Console and Terminal modes stay

| Changes | Stays as it is for now |
|---|---|
| Tool and activity rows, the running line, a new checklist | Console mode |
| Run status bar, request form, your message bubble, composer | Terminal mode |

Pretty is drawn by the focused worker, coordinator, wall tile and PiP, so a change reaches all four. `TranscriptToolRow` also serves outside Pretty, so add new views and do not restyle it. A whole-app and terminal restyle is a separate proposal: [app-restyle.md](app-restyle.md).

## CopilotKit has no Claude Code theme that I could find

- I searched CopilotKit's docs, the web and its repository, including the design-system themes in `a2ui-playground`, the `reskinnable-demo` and the open chat redesign PR. I found no official theme or preset with a Claude Code look.
- It has Claude **SDK integration examples**, which connect a Claude agent to a CopilotKit chat. The one stylesheet I read is a plain white chat.
- What it does offer is [CSS variables](https://docs.copilotkit.ai/custom-look-and-feel/css), replaceable component slots and a headless mode.
- License: [MIT](https://github.com/CopilotKit/CopilotKit/blob/main/LICENSE).
- If you saw a specific theme, send a link and I will check it.

You may be thinking of this repository's own [CopilotKit console proof of concept](../../poc/agui-console/README.md). It uses CopilotKit's runtime with a custom terminal-style React UI.

Pretty is **native SwiftUI**. CopilotKit is React and has no SwiftUI SDK.

| Reuse | How |
|---|---|
| Layout and interaction ideas | Yes. Rebuild them in SwiftUI. |
| Colours and type | Not needed. Use `design/system/tokens.json`. |
| React components and CSS | No, unless Pretty moves to a web view. I do not recommend that. |
| The AG-UI event model | Already in use. |

The target look comes from your Claude Code desktop screenshots. Copy its structure, not Anthropic's branding.

## Some things the data cannot show yet

| Wanted | Today | Needed |
|---|---|---|
| "Delegated…", "Asked…" with the real subject | Most Commander call arguments are dropped on purpose | Keep a short allow-listed summary per tool, in `internal/service/commander_activity.go` |
| "Created the task worktree" for a shell command | The model's `description` is not kept | Carry it from the ACP update |
| A name for `commander_status` calls | The older Claude runner records their results but not the calls | Record the call, in `internal/provider/runner.go` |
| Revision and tests under a reported result | Not kept over ACP | Keep both |
| Task checklist | A plan arrives as `[ACP plan] N items` | Carry the entries, in `internal/provider/acp_activity.go` |
| "1m 58s" on the running line | A console event has no time | Add a start time to `ConsoleEvent` |

Both runs you pointed at used that older runner (their events carry no ACP reference). It has no plan event: Claude's task list arrives there as `TodoWrite` calls, so the checklist also needs those todos kept. I did not check what Codex sends for plans outside ACP.

Keeping more argument text changes what the console stores and streams. Decide that before phase 2.

## One change, in this order

The user chose to build it all in one change: one issue, one worktree, one PR into `develop`.

1. Go: keep full tool arguments, command descriptions, plan entries, `TodoWrite` todos, call start times, `commander_status` calls, and `revision` and `tests` on results. Files: `internal/service/commander_activity.go`, `internal/service/agui.go`, `internal/service/store.go`, `internal/acpprocessor/`, `internal/provider/` (`acp_activity.go`, `acp.go`, `history.go`, `runner.go`).
2. A Settings › Transcript setting, stored with the service, that masks secrets or limits large values. Default: keep everything as sent. Also: a way to cancel a queued follow-up, a time on result events, and shortening large results by structure so they stay readable.
3. Swift: sentences, groups, typed result renderers and checklist (`ActivityStory.swift`, `ConversationActivity.swift`, `CommanderActivity.swift`, `CommanderToolCatalog.swift`, `ActivityStoryViews.swift`, new group and renderer views, `ConsoleDisplay.swift`, `FocusedPrettyConsole.swift`, `AGUIProjection.swift`, `Components.swift`).
4. Swift: status bar, request form, bubble and composer, with new queue and Stop controls.
5. Tests, `DESIGN.md`, `design/system/ATOMIC-DESIGN.md`, `design/PATTERN-DECISIONS.md`.

Verify the focused worker, coordinator, wall tile and PiP against the mockup. Console and Terminal modes must look unchanged.

## Decisions (answers from 2026-11-26)

| Question | Decision |
|---|---|
| Group default | Closed everywhere |
| Report that repeats the closing message | Clamp the report with "Show all" |
| Failures | "Blocked" tag and plain words for known denials; exact text one click away |
| Usage, mode, session, thinking | Fold into groups; warnings stay visible |
| Also restyle | Status bar, request form, bubble, composer |
| Composer | Restyle, and add queue and Stop |
| Live line and checklist | Inline in the transcript |
| What the service keeps | Full arguments |
| Safeguard | Configurable; **default shows everything as sent** |
| Build order | All in one |

**Accepted risk:** with the default, a secret in a tool argument is stored by the service and shown on every surface that draws the transcript, PiP included. I did not check whether it can reach people you share a run with over the network. Check that before building step 1.

## Open

- None on direction. On 2026-11-26 the user chose option C, "Two speeds", for the whole app: see [app-restyle.md](app-restyle.md).
