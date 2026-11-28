# Edge cases from transcripts and ACP

What the design did not cover on 2026-11-26, and where each case was seen. Counts are record types only, from the 250 newest local Claude transcripts and 48 Codex sessions. No conversation text was read out.

"Today" describes the code as searched, not a running app. The design for each row is in section H of [the spec](pretty-conversation.md).

## Seen in ACP (`github.com/coder/acp-go-sdk` v0.20.0)

| Case | Today | Add |
|---|---|---|
| Tool content `diff` | Not on the console event; the full update is kept in the worker's scoped history | Inline diff with added and removed counts |
| Tool content `terminal`, `terminal/*` | Not kept | Terminal output renderer, exit state |
| Tool `locations` (path, line) | Not kept | "Open at line" on file sentences |
| Tool `kind`: read, edit, delete, move, search, execute, think, fetch, switch_mode, other | Kept on the call's stored details (`tool_kind`), with its title | Picks the verb for tools Commander does not know (built) |
| Content blocks: image, audio, resource, resource link | Prompt media only is designed | Thumbnails, audio control and links in results and replies |
| Stop reasons: `max_tokens`, `max_turn_requests`, `refusal`, `cancelled` | Exposed as `control.last_stop_reason`; no Swift type reads it | End-of-turn line saying why it stopped |
| Permission option kinds: `allow_once`, `allow_always`, `reject_once`, `reject_always` | Choices keep ID and label only | Order and style by kind; "always" worded distinctly |
| `elicitation/create`, `elicitation/complete` | Built (forms and URLs); on only with `AGENT_COMMANDER_ACP_ELICITATION=1`, local workers | Restyle in the request form language |
| `plan_update`, `plan_removed` | Arrive as `[ACP kind]` lines with no content | Update or remove the checklist |
| `notice` | Off unless `AGENT_COMMANDER_ACP_SESSION_ACTIVITY=on` | Notice line; warnings stay visible |
| `compaction_update`, `compaction_summary_chunk` | Same switch | "Conversation compacted" divider |
| `subagent_update`, child permission declined | Flattened to text | Background job line (see the spec) |
| `session_message`, `session_message_chunk` | `[ACP kind]` lines; chunks carry text | "Message from X >" line |
| `prompt_suggestions_update` | A line with a count only | Suggestion chips above the composer |
| `available_commands_update` | A quiet line | Also feed a composer command menu (new feature) |
| History gap | Not designed | "Some history is missing here" row |

## Seen in Claude and Codex transcripts

| Case | Seen | Add |
|---|---|---|
| Failed results by cause: hook blocked 257, permission denied 116, user declined 26, timed out 6, interrupted 2, other 2064 | Claude | Hook and timeout words in the known-failure table |
| API error | Claude (47 flagged messages) | "The model request failed" line |
| Compaction boundary and summary | Claude 404, Codex 10 | Same divider as above |
| Turn duration; turn aborted | Claude 11905; Codex 30 | "Worked for 3m 12s"; "Stopped" |
| Agent-to-agent messages and spawning | `SendMessage`, `Agent`; `send_message`, `spawn_agent`, `followup_task`, `wait_agent` | Message line and background job line |
| Question tools | `AskUserQuestion` 220; `request_user_input`, `request_user_input_async` 49 | Choice card |
| Plan approval | `ExitPlanMode` 24 | Plan document with approve and reject |
| Waiting and scheduled work | `Monitor`, `CronCreate`; `sleep`, `wait` | Background job line |
| Tool loading | `ToolSearch` 1311 | Summary phrase "loaded tools" |
| Deliverables | `Artifact`, `SendUserFile`, pull request links | File or link card |
| Hook messages | `hook_system_message`, `hook_non_blocking_error` | Quiet line; blocking ones stay visible |
| Goal and task status | `goal_status` 1429, `task_status` 314 | Feed the job or checklist line |
| Codex code-mode `exec` and `js` | 2967 calls | Recognize them; today's list has `exec_command`, not `exec` |
| Images in results | Claude 3010 parts | Thumbnail |
| Server-side tools | `server_tool_use`, advisor results | Sentence as for any tool |

## Needs a decision: new features, not transcript design

ACP also offers `session/fork`, `session/list`, `session/resume`, `session/set_mode`, `session/set_title`, `session/archive` and `auth/status`. None is in a plan, so none is designed here.
