# Agent Commander development

## Ownership

Claude Fable 5.2 owns the native interface design and its Swift implementation. Give Fable the relevant original Agent Commander screenshots and component contracts when assigning interface work. Codex owns the service, API, MCP, CLI, tmux providers and backend tests. Codex independently verifies the running native app through Computer Use, exercises the real workflow, and compares captures with the approved screenshot for each implemented state. Send visual defects back to Fable for correction.

Keep all design tokens, components, fixtures and assets in this repository. The repository named `design-system` is a separate project.

## Native UI

Apply Brad Frost’s Atomic Design strictly to each implemented view. Start with the [component map](design/system/ATOMIC-DESIGN.md) and [local tokens](design/system/tokens.json). Compose native controls and styled atoms into molecules, then feature organisms, layout templates and pages. A standard native control can serve directly as an atom. Share component implementations between the wall, zoom and PiP when they have the same responsibility. Components receive values and emit targeted actions. The API and feature models own domain operations and subscriptions.

When changing a screen, identify its actual Swift components and compare the rendered state with the matching [original screenshot](design/concepts/index.html). Record any visible differences that matter. Use the approved coordinator wall and PiP as the starting point for the local build.

## Backend

Before implementing a flow, consult the [existing GoF and Enterprise Integration Patterns decisions](design/PATTERN-DECISIONS.md). Make a short note for a new boundary or changed approach. Deliver working increments as described in the [MVP plan](MVP-PLAN.md).

## Git worktrees

- Create linked Git worktrees under `~/.worktrees/<repo-name>/<worktree-name>/`. Use the repository name from the `origin` URL, or the primary checkout directory name if there is no `origin`. The worktree name is a single directory component and can differ from the branch name.
- Use `git worktree add` with the full destination path. In Codex, attach the resulting checkout or open it as a local workspace. In Claude Code, start the session from the resulting checkout. Use this workflow whenever the built-in worktree allocator cannot produce the required path.
- Use `git worktree move` to relocate an existing linked checkout and `git worktree list` to confirm its registered path.
