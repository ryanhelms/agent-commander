# Agent Commander development

## Ownership

Use Claude Opus for every new Commander-managed Claude session and project Claude agent. Leave provider-internal model routing to Claude.

- **Frontend** (native interface design, Swift UI code, mockups and design artifacts): Claude only, never Codex. Use the latest Fable model (currently Fable 5.2). Use the latest Opus model (currently Opus 5.5) only when usage limits prevent Fable. Every frontend task loads the `frontend-design` skill first. Give the frontend agent the relevant original Agent Commander screenshots and component contracts.
- **Backend** (service, API, MCP, CLI, tmux providers, the Go relay, and backend tests): Codex or Claude.
- **Verification**: Codex independently verifies the running native app through Computer Use, exercises the real workflow, and compares captures with the approved screenshot for each implemented state. Send visual defects back to the frontend agent for correction.

## Working style

- Run independent pieces in parallel subagents, split between Codex and Claude, whenever the work allows it. Maximize throughput and completed work.
- Ship visible progress quickly. Cover the main path first; don't hold a working increment back to fix every edge case.
- Build only what the plans describe ([MVP plan](MVP-PLAN.md), the design documents under `design/`). Don't invent functionality that isn't in a plan; propose it first.

Keep all design tokens, components, fixtures and assets in this repository. The repository named `design-system` is a separate project.

## Using this Mac

Any session or agent may use this Mac whenever the work needs it, without asking first. This includes Computer Use, accessibility automation, AppleScript, keyboard and mouse input, screenshots, and launching and driving apps, the user's live Agent Commander among them. It also includes toggling system settings for a test.

- Restore any system setting you change, and say in your report what you changed and restored.
- Coordinate a quit or relaunch of the user's live app with them first, as described under Native UI.
- Report which windows you drove, so other sessions' demos are not confused by it.

## Native UI

Use the primary checkout’s `dist/Agent Commander.app` for the user-facing cockpit. Its name is **Agent Commander** and its bundle identifier is `local.agentcommander.cockpit`. Run `make run` in that checkout to build it on first use or reopen the existing bundle through Launch Services. Use the same app for interactive QA and session demos. Coordinate an explicit quit and reopen before rebuilding a running app or changing its launch arguments or environment. Preserve the developer’s chosen `CODE_SIGN_IDENTITY` for subsequent builds. Use headless fixtures for independent verification while the user is working in Commander.

Apply Brad Frost’s Atomic Design strictly to each implemented view. Start with the [component map](design/system/ATOMIC-DESIGN.md) and [local tokens](design/system/tokens.json). Compose native controls and styled atoms into molecules, then feature organisms, layout templates and pages. A standard native control can serve directly as an atom. Share component implementations between the wall, zoom and PiP when they have the same responsibility. Components receive values and emit targeted actions. The API and feature models own domain operations and subscriptions.

When changing a screen, identify its actual Swift components and compare the rendered state with the matching [original screenshot](design/concepts/index.html). Record any visible differences that matter. Use the approved coordinator wall and PiP as the starting point for the local build.

## Design

[DESIGN.md](DESIGN.md) is the visual source of truth for every surface: the main window, zoom, PiP and the network tray. Read it before any design or interface task, including new views, restyles, components, tokens, motion, mockups and UI defect fixes.

- Use its tokens and component inventory. Reuse an existing atom or molecule before adding one.
- If a view needs something DESIGN.md does not cover, propose the addition and update DESIGN.md in the same change. Do not invent a one-off style.
- Keep the console, terminal and pretty view rendering as it is. The design applies to everything around them.
- When a change adds or alters a component, token or motion, update DESIGN.md in the same commit.

## Backend

Before implementing a flow, consult the [existing GoF and Enterprise Integration Patterns decisions](design/PATTERN-DECISIONS.md). Make a short note for a new boundary or changed approach. Deliver working increments as described in the [MVP plan](MVP-PLAN.md).

Use the [design pattern index](.context/design-patterns/index.md) to find a pattern by problem or category. Follow its “Commonly Used With” links when designing related behavior. Treat the examples as design references and the decision record as the source for project adoption.

Build the new multiplayer relay in Go. Follow the [relay architecture](design/MULTIPLAYER-RELAY.md) for connection ownership, one-to-many delivery and extension contracts.

## Git worktrees

- Create linked Git worktrees under `~/.worktrees/<repo-name>/<worktree-name>/`. Use the repository name from the `origin` URL, or the primary checkout directory name if there is no `origin`. The worktree name is a single directory component and can differ from the branch name.
- Use `git worktree add` with the full destination path. In Codex, attach the resulting checkout or open it as a local workspace. In Claude Code, start the session from the resulting checkout. Use this workflow whenever the built-in worktree allocator cannot produce the required path.
- Use `git worktree move` to relocate an existing linked checkout and `git worktree list` to confirm its registered path.
