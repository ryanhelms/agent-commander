# Pretty as a conversation: design spec

Proposal only. No app code, token or DESIGN.md change is made here. Mockup: [pretty-conversation.html](pretty-conversation.html).

**The change in one line:** each tool call becomes a sentence in the agent's turn; finished sentences fold into one summary line; a failure, a pending request and a reported result never fold.

**This needs a rule lifted.** DESIGN.md and `.claude/rules/design.md` say Pretty's rendering stays as it is, and ATOMIC-DESIGN.md says activity lines are "never collapsed behind a count". Building this changes the activity rows inside Pretty (not the console, terminal, Markdown blocks, bubble, status bar or request form). Both documents must be updated in the same change.

Marks used below:

- **SVC** = needs a service change. The fallback column is what ships without it.
- "name", "path" and so on in *italics* are values read from the call or its result. Quoted values are shown exactly.

## A. Mapping: current form to proposed sentence

### Rules that apply to every row

| Rule | Detail |
|---|---|
| Tense | Running: present participle, in the live line. Succeeded: past tense. Failed: "Couldn't …", then the reason. |
| Blocked | A call the provider refused permission for reads `Blocked`, not `Failed`: the tool never ran. It is told from the provider's own denial (ACP permission outcome, or Claude Code's "Permission to use … has been denied"). Any other failure stays `Failed`. The summary counts "N blocked" and "N failed" apart. |
| Failure reason | The first sentence after `Tool failed.\n`, exactly as sent, on its own line in secondary ink. The rest stays in the raw detail. No reason sent: "No reason was given." |
| No "Complete" | Success shows no status word. A state tag appears only for a state that is not plain success: `accepted`, `starting`, `running`, `waiting`, `partial`, `uncertain`, `cancelled`. |
| Accepted is not done | Delegate, send, interrupt, stop, integrate and submit say what was *asked*. The tag carries the run record's state, read by exact ID. Without a run record the tag is `accepted`. |
| Where facts come from | Over ACP a Commander call keeps no arguments, only correlation IDs. So each sentence reads the tool result first, then the run record by exact ID, then the call text, then the fallback. |
| Counts | A count is stated only when the result holds exactly one list to count. Otherwise the fallback. |
| Repeats | Identical consecutive calls with identical outcome merge into one line with a count tag (`7 checks`). Each call stays inside it. |

### Commander tools (23)

| Tool | Current card | Running | Succeeded | Failed | Fallback without the value | Summary phrase |
|---|---|---|---|---|---|---|
| `commander_delegate` | "Delegate worker", name, Accepted | Starting a worker | Delegated to a new worker, *name* `tag` (name from result `name`) | Couldn't start a worker | Delegated to a new worker | delegated to *name* / delegated to N workers |
| `commander_ask` | "Question" card with timeline | Asking | Asked: "*question*" (call text, or `run.requests` by ID) | Couldn't send the question | Asked a question (request *short ID*) | asked a question |
| `commander_wait` | Milestone "Waiting for reply" | Waiting for a reply | Got the answer: "*answer*"; still pending: Waited for a reply `N checks` | Couldn't wait for the reply | Waited for a reply | waited for a reply; with its ask and answer: asked a question and got an answer |
| `commander_reply` | "Reply" card | Replying | Replied to *worker*: "*answer*" (both from `run.requests` by ID); not confirmed: Sent a reply `uncertain` | Couldn't send the reply | Replied to a question (request *short ID*) | replied to a question |
| `commander_reconcile_reply` | Milestone "Delivery reconciled" | Checking whether the reply arrived | Checked the reply: delivery *delivery* | Couldn't check the reply | Checked a reply's delivery | checked a reply |
| `commander_result` | "Report result", Complete, no text | Reporting | **Prose block**, not a line. Heading "Reported to the coordinator" (worker) or "Reported the run result" (coordinator); body is result `result` as Markdown. Revision and tests under it when the run record has them | Couldn't report the result (always visible) | Line "Reported a result" when no text is found | none: never in a group |
| `commander_commit` | "Commit" card | Committing | Committed *N* files: "*message*" `rev short` (SVC: files and message are dropped over ACP) | Couldn't commit | Committed changes (`rev short` when the result has it) | committed changes / made N commits |
| `commander_integrate` | "Integrate" card | Starting an integration | Asked to integrate *N* workers' changes `tag` (status from `integrations` by ID) | Couldn't start the integration | Asked to integrate changes `accepted` | started an integration |
| `commander_send` | "Send follow-up" | Sending a follow-up | Sent *worker* a follow-up `tag`; text shown in the detail when kept | Couldn't send the follow-up | Sent a follow-up to a worker `accepted` | sent a follow-up / sent N follow-ups |
| `commander_interrupt` | "Interrupt worker" | Interrupting | Asked to interrupt *worker* `tag` | Couldn't interrupt *worker* | Asked to interrupt a worker `accepted` | asked to interrupt a worker |
| `commander_stop_worker` | "Stop worker" | Stopping | Asked to stop *worker* `tag` | Couldn't stop *worker* | Asked to stop a worker `accepted` | asked to stop a worker |
| `commander_status` | "Check status" | Checking worker progress | Checked the run: *N* workers, *M* running (counted from result `workers[].state`) | Couldn't check the run | Checked worker progress | checked progress / checked progress N times |
| `commander_list_tools` | "List extensions", "0 tools" | Listing extensions | Found *N* extensions / Found no extensions granted | Couldn't list extensions | Listed extensions | listed extensions |
| `commander_call_tool` | "Call extension" | Calling extension *id* | Called extension *id* | Extension *id* failed | Called an extension | called an extension / called N extensions |
| `commander_network_inbox` | "Read network inbox" | Reading the network inbox | Read the network inbox: *N* messages / no messages | Couldn't read the network inbox | Read the network inbox | read the inbox |
| `commander_network_discover` | "Discover network" | Looking for shared resources | Found *N* shared resources / Found no shared resources | Couldn't look for shared resources | Looked for shared resources | looked for shared resources |
| `commander_network_submit` | "Relay operation" card | Sending an operation | Sent an operation to *N* resources `tag` (status from its receipts by operation ID) | Couldn't send the operation | Sent a network operation (*short ID*) `accepted` | sent an operation |
| `commander_network_receipt` | Milestone "Receipt: …" | Checking the receipt | Receipt: *status word*; repeats with the same status merge | Couldn't read the receipt | Checked a receipt | checked its receipt (omitted when its submit is in the same group) |
| `commander_network_online` | "See who is online", "Tool failed." | Seeing who is online | *N* contacts, *M* online (counted only when each contact carries `online`) / No contacts to show (`friends: []` is an empty contact list, not "nobody online") | Couldn't see who is online | Checked who is online | checked who is online |
| `commander_network_thread` | "Read request thread" | Reading a request thread | Read a request thread: *N* comments / no comments. A comment added cannot be told apart (SVC: keep that `text` was sent) | Couldn't read the thread | Read a request thread | read a thread |
| `commander_network_board` | "Work task board" | Opening the task board | Result has `workspaces`: Opened the task board: *N* workspaces / no workspaces. Claim, release, complete and comment cannot be told apart (SVC: keep `op` and `card`) | Couldn't use the task board | Used the task board | used the task board |
| `commander_frontend_tools` | "List app tools" | Listing app tools | Found *N* app tools / Found no app tools | Couldn't list app tools | Listed app tools | listed app tools |
| `commander_call_frontend` | "Call app tool" | Using app tool *name* | Used app tool *name*; result `error` set: failed line with that error | App tool *name* failed | Used an app tool | used an app tool / used N app tools |

### Provider tools and other records

| Record | Current form | Running | Succeeded | Failed | Fallback | Summary phrase |
|---|---|---|---|---|---|---|
| Read | "Read file" card, path | Reading *file* | Read *file* (file name; full path in help and detail) | Couldn't read *file* | Read a file | read a file / read N files |
| Edit | "Edit file" card | Editing *file* | Edited *file* | Couldn't edit *file* | Edited a file | edited a file / edited N files |
| Write | "Write file" card | Writing *file* | Wrote *file* | Couldn't write *file* | Wrote a file | wrote a file / wrote N files |
| Grep, Glob, search, ls | "Search" card | Searching for "*pattern*" | Searched for "*pattern*" | Search for "*pattern*" failed | Searched files | ran a search / ran N searches |
| Bash and other shells | "Run command" card | Running `command` | Ran `command` (first line, mono, cut in the middle). ACP title that differs from the command: the title as sent. With the model's description (SVC): the description, command in the detail | `command` failed, then exit state or first error line | Ran a command | ran a command / ran N commands |
| Web search | "Web" card | Searching the web for "*query*" | Searched the web for "*query*" | Web search failed | Searched the web | searched the web |
| Web fetch | "Web" card | Fetching *host/path* | Fetched *host/path* | Couldn't fetch *host/path* | Fetched a page | fetched a page / fetched N pages |
| `TodoWrite` (older Claude runner's task list) | Raw `TranscriptToolRow` | Updating the plan | Checklist card (SVC: keep the todos from the call's input) | Couldn't update the plan | Updated the plan | none: the card stands alone |
| Unknown or other MCP tool | Raw `TranscriptToolRow` | Using `tool` | Used `tool` (wire name without the server prefix; full name in help) | `tool` failed | same; the wire name is always present | used another tool / used N other tools |
| Result with no recorded call | Raw "Tool result" block | none | Got a result whose call was not recorded | Failed result: stays a visible failure line with its reason | same | got N results with no recorded call |
| Thinking | "Thinking" disclosure | Thinking, in the live line | Thought: *first line*, italic. Opens to the full text | none | Thought | none; a group of only thoughts reads "Thought" |
| Usage, mode, commands, session lines | One visible mono line each | none | Folded into the surrounding group as its own line, wording unchanged ("Context …", "Mode …") | none | unchanged | none; a group of only these reads "N session updates" |
| stderr, permission notice, other attention-tone events | Visible line in attention ink | none | Unchanged, and never folded | none | unchanged | none: breaks the group |
| Plan | Provider line "[ACP plan] N items" | none | Checklist card: done, in progress, pending. One per turn, updated in place (SVC: pass plan entries) | none | Line "Updated the plan: N items" | none: the card stands alone |
| Permission request | Request form; held call reads "Approval needed" | none | Unchanged form. Its lead reads "Needs your approval to *run `command`* / *use `tool`*" | none | "Needs your approval" | none: never collapsed |
| Question request | Request form; "Decision needed" card | none | Unchanged form, question quoted. The asking line above it reads "Asked: "…"" | none | "Needs your reply (request *short ID*)" | none: never collapsed |

## B. Grouping and expand/collapse

| Topic | Rule |
|---|---|
| What groups | A run of consecutive finished calls and quiet lines inside one agent turn. Calls linked by an exact request, operation or revision ID are one line inside the group (the existing `CommanderWorkflow`). |
| What breaks a group | Agent prose. A user prompt. A failed call. A reported result. A pending question or permission request. A plan card. An attention-tone event. The open (running) call. |
| A group of one | No summary line. The sentence stands alone with its own chevron. |
| Summary composition | One phrase per kind, in order of first appearance, joined by commas, first letter capitalised. Same kind adds up ("ran 3 commands"). A single named item keeps its name ("delegated to reader"). |
| Cap | Three phrases, then "and N more steps". |
| Failures | A failed call is taken out of the count and drawn as its own line directly under the summary, open or closed, with its reason. The summary ends with "N failed" in failure ink. A group whose calls all failed has no summary, only the failure lines. |
| Default state | Closed, everywhere. A non-success tag inside a closed group is named on the summary line. Open state is kept per console by the first call's ID, as today (`ConsoleModeStore`). |
| Live behaviour | The open call is the live line under the group: spinner, sentence, elapsed time. When it ends it joins the group and the summary recounts. The summary never animates. Nothing else moves. |
| Elapsed time | SVC: events carry no time. Until then the live line shows no time. It does not show a client-side guess. |
| Second level | A line opens to a typed view of its call and result (section E): words, labelled fields, lists, tables, lamp and word. No wire name, tool ID or raw JSON by default. A workflow line opens to its milestone timeline first, then each call's typed view. |
| Regular (coordinator, focused worker) | Everything above. Report shown in full. |
| Compact (wall tile) | Same parts, tighter spacing. Report clamps to 6 lines with "Show all". Failure reason wraps. |
| PiP | The latest group, every failure, the report (clamped to 3 lines), the live line. An open group shows its first and latest three lines, then "Show all N". |
| Keyboard | Summary and lines are native buttons in tab order. Space or Return toggles. Right opens, Left closes, as a native disclosure. Option-click opens every level beneath. |
| VoiceOver | Summary: "Activity, 4 steps, 1 failed. Ran 3 commands, read 2 files", value "Collapsed" or "Expanded". Line: its sentence, then its tag, then "failed" and the reason. The live line is announced politely once, not on every tick. |
| Raw detail stays reachable | Every opened view ends with one quiet **Source** action. It shows the wire name, tool ID, the call and the result text (JSON pretty-printed; Copy keeps the exact text) (the existing `TranscriptToolRow` and `RecordFieldsPanel`). Nothing is dropped from `ActivityStory.evidence`. |

## C. Components

| Level | Component | Status | Notes |
|---|---|---|---|
| Value | `ActivitySentence` (in `ActivityStory.swift`) | New | Pure wording for a call or workflow: running, succeeded, failed, fallback, summary phrase, tag. Table A is its test fixture. |
| Value | `ActivityStory` | Change | Gains `sentence`, `summaryPhrase`, `failureReason`. `kind`, `lead`, `context` retire with the header. Honesty rules and `assemble` stay. |
| Value | `ConversationActivity.items` | Change | Produces groups under the rules in B. Quiet events join groups; attention events do not. |
| Value | `CommanderTool` | Change | `runningPhrase` covers all 23. `label` stays for help text and VoiceOver. |
| Value | `ProviderTool` | Reuse | `fact(from:)` supplies the file, pattern, command or URL. |
| Atom | `ActivityStatusMark` | Change | Used only as the small state tag on a line. No "Complete" form in Pretty. |
| Atom | Spinner | Reuse | The live line and the plan's in-progress item. |
| Molecule | `ActivityLine` | New | One sentence, optional tag, chevron. Replaces `ActivityStoryHeader`. |
| Molecule | `ActivityGroupSummary` | New | The secondary-ink summary line and its "N failed". |
| Molecule | `ActivityFailureLine` | New | Sentence in failure ink, `Blocked` or `Failed` tag, reason beneath, opens to the failure renderer. |
| Molecule | `PrettyReportBlock` | New | Heading line and the result as Markdown through `PrettyAssistantTurn`'s blocks. Copy keeps the exact text. |
| Molecule | `PrettyLiveLine` | Change of `PrettyRunningIndicator` | Same position and spinner; sentence from `ActivitySentence`; elapsed time when the service sends a start time. |
| Molecule | `PrettyPlanCard` | New, SVC | Checklist from ACP plan entries. |
| Molecule | `ActivityMilestoneTimeline`, `ActivityRelationList`, `ActivityActionGroup` | Reuse | Inside an opened line. |
| Molecule | `ActivityToolDetails` | Change | Becomes the opened line's body; the "Tool details" label goes. |
| Molecule | `TranscriptToolRow`, `ToolResultStatusLine`, `PrettyRawBlock` | Reuse | Behind Source only. |
| Molecule | `PrettyThinkingRow` | Change | Drawn as an `ActivityLine` ("Thought: …"); the open state keeps its italic text and rule. |
| Molecule | `PrettyActivityRow`, `PrettyActivityRun` | Change | Rows stay for attention events and inside groups; the run wrapper retires. |
| Organism | `ActivityGroup` | New | Summary, list of lines, failure lines beneath. |
| Organism | `ActivityStoryCard`, `ActivityStoryHeader` | Retire | Replaced by `ActivityGroup` and `ActivityLine`. |
| Organism | `PrettyConsoleView`, `PrettyACPConsole` | Change | Compose the new parts. `PrettyRunStatusBar`, `PrettyRequestForm`, `PrettyUserTurn`, Markdown blocks and tables are untouched. |

Tokens: no new colours or type. Pretty reads no theme and keeps its own `Palette` and `Term` roles, exempt from the 2 pt corner rule. The mockup's 9 pt list and 5 pt tag corners match the black-glass `control` and `chip` values; add them as Pretty constants in `PrettyMetrics`, not as a theme lookup. Existing Pretty corners (bubble, code, raw) stay.

## E. The opened line: typed result renderers

A result is drawn by what it holds, never as JSON. Shapes below are read from `internal/mcpbridge` and the service handlers; "unverified" marks the ones I could not confirm field by field.

### What every opened line has, in order

1. **Typed body**, from the renderer the shape selects.
2. **State with its origin**, when the body has a state. "when this call returned" is the call's own result, a snapshot. "now, from the run record" is read by exact ID and is newer. Both show when they differ; only the snapshot shows when the run record does not hold the ID. In run1 the delegate result says `starting`, the status result two steps later says `working`, and the run record now says `completed`. The line's tag is always the "now" value.
3. **More fields**: every property the renderer did not place, drawn by the generic renderer behind "N more fields, M empty".
4. **Source**: closed by default. Wire name, tool ID, call text and result text. Text that is JSON is pretty-printed: two-space indent, one property per line, key order as sent, monospaced, with JSON inside a string left as a string. JSON cut off by the 16 KB limit is indented as far as it goes and marked as cut. Other text shows as sent. Copy always copies the exact original text. The same rule applies anywhere else JSON text would show, such as terminal output.

### How a renderer is selected

| Step | Rule |
|---|---|
| 1. Unwrap | MCP content list, `structuredContent`, a JSON string, a code fence (the existing `CommanderPayload`). Then the network wrapper `{"ok":true,"data":…}`: `data` is the result; `ok:false` or an `error` goes to the failure renderer. Non-text MCP parts (image, resource) become attachment rows through the existing `RecordDataURL`. |
| 2. Failure | A failed phase, `isError`, `ok:false`, or a non-empty `error` selects the failure renderer, whatever the tool. |
| 3. Tool's renderer | A known tool names its renderer and the properties it needs. It is used only when those properties are present with the expected types. |
| 4. Shape | Otherwise the first matching shape in the table below, whatever the tool. This is why a run status with no recorded call still draws as a roster. |
| 5. Generic | Anything else, including every unknown MCP tool. |
| Extra or unexpected properties | Each renderer declares the properties it placed. All others go to "More fields" through the generic renderer. A property of the wrong type is not placed: it goes to "More fields" too. Nothing is dropped. |

### Renderers

| Renderer | Selected by shape | Tools (response) | Shows, in order | Empty state |
|---|---|---|---|---|
| Worker card | object with `role`, `state`, `task` | `delegate`, `stop_worker` (a Worker) | name and role with its parent's name; state then and now; task (4 lines, then "Show all"); host and client; worktree and branch; created; result or error when set | none: a worker always has a name and state |
| Run roster | object with `workers` list and `status` | `status` (projected run: `id, project, path, task, client, coordinator_id, status, workers[], requests[], integrations[]`) | project and run status; folder; task (collapsed); worker table (name, role, state, host, first line of result; a row opens its worker card); requests as question cards; integrations as receipts | "No workers." "No open requests." |
| Question card | object with `question`, `status` | `ask` (a Question), `wait` (the same, latest read), `reconcile_reply` (unverified) | question quoted; status; answer quoted or "No answer yet"; who asked; delivery; choices as a list | "No answer yet." |
| Acknowledgement | object of up to 3 scalars | `reply` (`{id, state}`: the asking worker and its state), `commit` (`{revision}`) | one labelled row per scalar: "Worker reader, now working"; "Revision 1a2b3c4" with copy | none |
| Report | `{id, result}` | `result` | the text is already prose in the conversation. Opened: who reported, where it goes, revision and tests table (command, outcome) when sent | "No tests or revision sent." |
| Operation receipt | object with an ID, a status and a list of per-target records | `network_submit`, `network_receipt` (unverified fields), `integrate` (`id, workers, revisions, target{path,branch,base}, candidate{status, detail, tests, revision, path}`) | operation ID and status with origin; one row per target (resource, action, outcome, result); for an integration: workers by name, revisions, target branch and base, candidate status and detail, combined test output as terminal output | "No targets reported yet." |
| Follow-up | object with `text`, `status`, `generation` | `send` (`id, status, text, generation, end, stop_reason`) | the text quoted; status with origin; target worker; stop reason when set | none |
| Control state | object with `held`, `generation` | `interrupt` (the worker's control: `held, interrupt_requested, interrupt{phase, outcome}, messages[]`) | interrupt phase and outcome; whether the developer holds input (Yes or No); queued follow-ups as a table | "No queued follow-ups." |
| Record table | list of objects sharing most keys | `list_tools` (`tools[]: id, version, action, description, input_schema`), `frontend_tools` (`name, description, parameters`), `network_discover` (unverified: resources with actions and `actionContracts`), `network_online` contacts, `network_board` workspaces, claims, cards (unverified) | up to 5 columns in first-seen order, identifying column first; other columns and nested values behind the row; a JSON Schema draws as "field, type, required" rows | a sentence naming the thing: "No extensions are granted." "No contacts to show." "No workspaces." |
| Message list | list of objects with `text` and a sender or time | `network_inbox` (`messages[]: id, peer, resource, receivedAt, text`, plus `truncated`), `network_thread` comments (unverified fields) | sender, via which resource, time; text quoted; `truncated: true` reads "Older messages were left out." | "No messages." "No comments." |
| App tool result | text or `{content, error}` | `call_frontend` (the app's `content` as text; `error` fails the call), `call_tool` (the extension's own JSON) | the content through steps 1 to 5 again, so an extension's JSON gets a typed or generic body | "The tool returned nothing." |
| Text file | text whose lines start `N⇥` | Read | file name with its folder; line range and count; numbered lines in the terminal face; 12 lines, then "Show all" | "The file is empty." |
| Change | old and new text, or a diff | Edit, Write | file; added and removed lines; Write shows line count and the first lines | "The provider sent no diff for this edit." |
| Terminal output | shell tool | Bash and other shells | the command as a prompt line; output in a well (last 12 lines, then "Show all"); exit state as lamp and word | "The command printed nothing." |
| Search results | list of paths, or `path:line:text` lines | Grep, Glob, ls | what was looked for; files with match counts; a file opens its matching lines | "Nothing matched." |
| Web results | list with `title` and `url`; or page text | web search, web fetch | search: title links with their address. Fetch: page title, address, size, text behind "Show the text" | "No results." |
| Checklist | list of objects with `content` and `status` | TodoWrite, ACP plan (both SVC today) | done, in progress, pending marks with the item text | "The plan is empty." |
| Failure | step 2 | any | what was tried; outcome (`Blocked` or `Failed`) with what that means; reason (first sentence, exact); the rest of the provider's message behind one disclosure | "No reason was given." |
| Generic | anything else | unknown MCP tools, unknown shapes, "More fields" | see the rules below | "Empty result." |

### Generic renderer rules

| Value | Drawn as |
|---|---|
| Key | Label in sentence case from the key (`created_at` → "Created at"). The exact key is in help and in Source. Order as sent. |
| Status-like key (`state`, `status`, `phase`, `outcome`, `presence`, `delivery`) | Lamp and the word as sent, capitalised. Tone only for words Commander knows; an unknown word gets the neutral lamp. |
| `true` / `false` | "Yes" / "No". |
| `null`, empty string, empty list, empty object | "none" / "empty". Counted in "M empty" and listed, never hidden. |
| ID (key `id` or ending `_id`/`Id`, or a `w-`, `r-`, `toolu_` value) | Short ID chip; full value in help and copy. Shown with the worker's or run's name when the run record holds that exact ID. |
| Path | Mono, cut in the middle, last part bright. Not opened or looked up. |
| Time (RFC 3339 value) | Local date and time; the exact value beside it in secondary ink. |
| Link | Link text without the scheme. |
| Number | Mono, as sent. |
| Short string | Plain text. |
| Multi-line or long string (over 280 characters) | A quoted block that keeps its line breaks, 6 lines then "Show all". A string that is itself JSON is parsed and nested. |
| List of scalars | Comma list up to 6, then a bulleted list. |
| List of objects | Record table when the items share most keys; otherwise numbered nested records. One item draws as a nested record. |
| Nested object | A disclosure labelled with the key and field count. Open when it has 4 or fewer scalar fields. Past 4 levels deep: "Deeper values are in Source." |
| Secret-looking key (`token`, `secret`, `password`, `authorization`, `cookie`, `credential`, `api_key`, `private_key`; not `idempotency_key`) or value (`Bearer …`, `sk-…`, a JWT) | Shown as sent by default. With the "Hide values that look like secrets" setting on (section F): "Hidden, N characters" with Reveal, hidden in Source too, and Copy needs Reveal first. |

### Hard cases

| Case | What renders |
|---|---|
| Result cut at 16 KB (`\n[Output shortened]`) | The marker is removed and a banner says "Commander kept the first 16 KB of this result. The end is missing." Whole properties before the cut render as usual. The property being written at the cut is marked "cut off"; later ones read "not received". A count from a cut list reads "at least N". If nothing can be read: "This result could not be read as data" with a closed "Show as text". |
| Empty result (`{"tools":[]}`, `{"data":{"friends":[]},"ok":true}`) | The renderer's empty sentence, alone. No table header, no braces. |
| MCP envelope | Unwrapped in step 1. The wrapper's own keys (`ok`, `content`, `type`) are read for status and are in Source, not in "More fields". |
| Long task text | 4 lines in a card, collapsed to its first line in a roster, with "Show all". |
| Plain text result from a tool expected to return data | Quoted block; no renderer is forced on it. |
| Provider text written for the agent (the "IMPORTANT: You may attempt…" part of a denial) | Behind "Rest of the provider's message, written for the agent". It is shown as text only; nothing in it is acted on. |

### Components added for section E

| Level | Component | Status | Notes |
|---|---|---|---|
| Value | `ResultShape` (new file `ActivityResult.swift`) | New | Steps 1 to 5 as a pure function from tool, call text and result text to a renderer case plus `placed` and `remaining` properties. Table-driven tests from run1 and run2. |
| Value | `TruncatedJSON` | New | Detects the shortened marker and recovers whole members. |
| Value | `ProvenancedState` | New | A state word with its origin: `callResult` or `runRecord`. |
| Value | `RecordFieldRows`, `RecordField` | Reuse, change | Already flattens a record's JSON into rows with decoded string leaves, data URLs and base64. Add value kinds (status, time, path, ID, secret) for the generic renderer. |
| Value | `CommanderPayload`, `CommanderCall` accessors | Reuse | Unwrapping and typed field reads. |
| Atom | `StatusLamp` word and lamp | Reuse | From the app's lamp-and-word atom; tone from `CommanderActivityStatus`. |
| Atom | `IDChip`, `PathText` | New | Short ID with copy; middle-cut path. |
| Molecule | `ResultFieldList` | New, on `RecordFieldRow` | Label and typed value rows. `RecordFieldRow` supplies selection, copy and decoded leaves. |
| Molecule | `ResultRecordTable` | New, on `PrettyTable` | Uniform list as a table with row disclosure. |
| Molecule | `ResultQuote`, `ResultEmptyState`, `ResultTruncationBanner`, `SecretValue` | New | Quoted text with clamp; the empty sentence; the 16 KB banner; hidden value with Reveal. |
| Molecule | `ResultMoreFields` | New | "N more fields, M empty" disclosure over `ResultFieldList`. |
| Molecule | `ResultSourceDisclosure` | New | The quiet Source action. Its body is the existing `TranscriptToolRow` plus the `RecordFieldsPanel` action from `RecordDetailHost`. |
| Molecule | `PrettyCodeBlock`, `PrettyRawBlock` | Reuse | Text file, terminal output, change. |
| Organism | `WorkerResultCard`, `RunRosterResult`, `QuestionResult`, `OperationReceiptResult`, `MessageListResult`, `FailureResult`, `GenericResult` | New | One per renderer above that is more than a field list; each composes the molecules. |
| Organism | `ActivityResultView` | New | Switches on `ResultShape`, then adds state origin, More fields and Source. Replaces `ActivityToolDetails` as the opened line's body. |

### Service needs added by section E

| Change | Why |
|---|---|
| Shorten structured results by structure, or keep the full result in the record and shorten only the preview | A 16 KB text cut leaves invalid JSON; a real run's status result passes 16 KB with a few workers that have reported. |
| A time on each result event | "when this call returned" could then say when. |
| `commander_interrupt` returns the whole control record, `commander_stop_worker` the whole Worker | Works today; a small receipt (`{worker, state}`) would be safer to render and smaller. |

## F. Decisions from the review

These override anything above that says otherwise.

| # | Decision | Effect on this spec |
|---|---|---|
| 1 | Groups start closed everywhere | No group opens by itself, including one holding an `accepted` or `uncertain` tag. The tag shows on the summary line instead: "Delegated to 2 workers, 1 accepted". |
| 2 | Report clamps when a closing message follows | A reported result shows its first 4 lines with "Show all" when the same turn ends with an agent message. It shows in full when nothing follows. |
| 3 | Failure wording | Tag `Blocked` or `Failed`. A denial Commander recognises gets short plain words from a fixed table ("Claude Code is in don't-ask mode."). Any other error shows the provider's first sentence. The exact text is the first row of the opened line. |
| 4 | What folds | Usage, mode, commands and session rows and thinking fold into the group. Warnings, stderr and permission notices stay visible. |
| 5 | The frame is in scope | The run status line, request form, prompt bubble and message box are restyled (below). |
| 6 | Message box | Restyle the follow-up composer; add queue-while-working and Stop. |
| 7 | Live line and checklist | Inline in the transcript, at the point they belong to. Not pinned. |
| 8 | Service keeps everything | Full tool arguments, descriptions, plan items and start times. Every "SVC" row above ships with that change. The fallback column is for records stored before it. Hiding and size limits become a setting, default off. |
| 9 | Build order | One change: service fields, sentences, grouping, renderers, frame. |

### Known-denial table (decision 3)

| Provider text contains | Tag | Plain words |
|---|---|---|
| "has been denied because Claude Code is running in don't ask mode" | Blocked | Claude Code is in don't-ask mode. |
| ACP permission outcome `rejected` or `cancelled` for this call | Blocked | You denied this. / The request was cancelled. |
| "permission does not match the active provider turn" (service) | Blocked | The approval was for an earlier turn. |
| "developer holds worker input" (service) | Blocked | Someone holds input for this worker. |
| anything else | Failed | The provider's first sentence, exactly. |

The table is data in one place (`ActivityFailureWords`), matched on whole phrases. An entry is added only for text seen in a real record.

### The frame (decision 5)

| Part | Today | Proposed | Function kept |
|---|---|---|---|
| Run status line (`PrettyRunStatusBar`) | "ACP" badge, session, dot and word, counts, on a footer fill | One quiet line: harness chip, lamp and word, counts in a sentence ("3 prompts, 14 tool calls, 1 blocked"), short session ID at the trailing edge. No fill; a hairline beneath. | Same values from `PrettyRunStatus`. Session help text and the full ID in VoiceOver. The ACP badge becomes help text on the harness chip. |
| Prompt bubble (`PrettyUserTurn`) | Trailing bubble | Same position; `selection` fill, 13 pt corner, body type, no caption. Attachment note stays beneath. | Media marker handling and the attachment action. |
| Request form (`PrettyRequestForm`) | Native reply form | A bordered block in the transcript: who asks and the short request ID, the question as prose, choices as full-width buttons with the first one primary, then a reply field. An approval shows what will run in the terminal face and Allow once / Deny. | Answered by exact request ID. Choices reply with the exact choice ID. One form per request on the surface that owns the reply. Offline, held, closed and sending states keep the form visible, disable input and say why in one line. |
| Live line (`PrettyRunningIndicator`) | Pinned under the transcript | Inline, last item of the transcript: spinner, sentence, elapsed time. | Same phase source. |
| Checklist | Not drawn | Inline card at the point the plan was sent; updated in place. | none |

### Message box (decision 6)

| | Exists today | New |
|---|---|---|
| Send a follow-up with files | Yes: `CockpitModel.sendFollowUp(to:text:context:)`, `FollowUpContextAccess`, `FollowUpContextChip`, `FollowUpContextMenu` | Restyle only: rounded field, 13 pt corner, "Add file" and the action at the bottom edge. |
| Queue while the agent works | The service already queues: a follow-up "runs when the worker is ready for a new turn" and has a status (`WorkerFollowUp.status`); hand-back already counts "queued follow-ups" | The box says so: placeholder "⌘↩ queues it while the agent works", the action reads Queue, and each queued message shows above the box as "Queued for the next turn: …" with Remove. Remove needs a cancel for a queued follow-up (not verified to exist). |
| Stop | Interrupt exists: `CockpitModel.interruptWorker`, service `/interrupt` (202, refused when there is no active turn or the developer holds input) | A square Stop button in the box while a turn runs. It interrupts the turn and keeps the conversation. It is not Stop worker, which stays in the worker's menu. When the service refuses, the button is disabled with the reason as help. |
| Idle | Send | The square becomes a Send arrow; ⌘↩ sends. |

I did not find a view named `TerminalComposer` by search; the composer view to restyle needs naming before work starts.

### Setting: what Commander keeps (decision 8)

| | |
|---|---|
| Where | Settings › Transcript, stored with the service so every client sees the same records. |
| Heading | Tool calls in the transcript |
| Option 1 (default) | **Keep everything as sent.** Full arguments and results, with no size limit. |
| Option 2 | **Hide values that look like secrets.** Tokens, passwords and keys show as "Hidden" with Reveal. |
| Option 3 | **Limit large values** to a size the user sets (16 KB offered). Longer values are shortened and marked. |
| Warning line, always visible under option 1 | With "Keep everything as sent", secrets an agent passes to a tool are stored and shown on every surface, including the PiP. |
| Scope | New records. Stored records keep what they have, so the shortened-result rendering in section E stays for them. |

Section E changes with this: the generic renderer shows a secret-looking value as sent under option 1, and as "Hidden" with Reveal only under option 2. Options 2 and 3 can both be on.

## G. Background work

A background job is work that goes on after its tool call returns. The call's line stays where it happened, in the past tense, with its tag (table A). The job gets its own line in a **background stack** at the bottom of the transcript, above the agent's own live line. Mockup: the "Background work" panel.

### What counts, and the record that drives it

Each state is read from the named record by exact ID. No record, no line.

| Job | Record and ID | Running when | Ended when |
|---|---|---|---|
| Delegated worker | `Worker` by worker ID | `state` is `starting`, `running` or `working` | `completed`, `failed`, `stopped` |
| Follow-up, queued message | `WorkerFollowUp` by message ID | `queued` (drawn "is queued", no spinner), `processing` | `completed`, `failed`, `cancelled`, `interrupted`, `delivery_unknown` |
| Interrupt, stop | `Worker` by worker ID | `stopping` | `stopped`, or the state the record holds |
| Question awaiting an answer | `Question` by request ID | `pending` (attention mark, no spinner) | `answered`, `cancelled`; `delivery` `unknown` or `unconfirmed` reads "delivery unknown" |
| Integration | `Integration` by integration ID, `candidate.status` | SVC: status values not yet mapped | the same |
| Network submit | Operation receipt by operation ID | `queued`, `processing` | `completed`, `failed`, `cancelled` |
| Provider child session (Claude Task or Agent tool, ACP `subagent_update`) | SVC: none today | | |
| Background shell command (`run_in_background`) | SVC: none today | | |

### The line

| State | Wording | Mark |
|---|---|---|
| Running, child has an open call | "**tracer**: Reading `runner.go`": the name, then the child's own live sentence, read from the child's console | Spinner |
| Running, nothing more known | "**tracer** is working" (or "is starting", "is stopping") | Spinner |
| Provider child or background command | Its own description as a participle and subject: "Writing option C into DESIGN.md" | Spinner |
| Finished | "**reader** finished" | Solid grey dot |
| Failed | "**tester** failed", `Failed` tag, the reason from `Worker.error` on its own line | Failure line |
| Needs you | "**reviewer** is waiting for your answer", with "Go to the question" | Attention dot |
| Stopped or cancelled | "**tracer** was stopped", `cancelled` tag | Solid grey dot |
| Delivery unknown | "Follow-up to **tracer**: delivery unknown", `uncertain` tag | Hollow dot |
| Worker `unknown` or `disconnected` | "**builder**: lost contact with its host. Last known: working." | Hollow dot |
| Claude progress stale (over 30 s, `ClaudeProgressDisplay`) | "**writer**: no progress reported for 45s" | Hollow dot |
| Service disconnected | One line first: "Not connected to the service. This is the last state it sent." Every line then reads "last known …" | Hollow dot, no timers |

**Spinner rule.** A spinner needs three things: the record says running, it was read by exact ID, and the service connection is live. Otherwise the mark is a hollow dot and the words say "last known". A completed tool call is never evidence that the job ran or ended.

### Behaviour

| Topic | Rule |
|---|---|
| Finish | The line changes in place to "… finished" and stays until the next user prompt. It links to the worker. A reported result still arrives as the report block; the finish line does not repeat its text. The call's own tag updates from the same record. |
| Failure | Never collapses, never counted away. It stays in the stack, open with its reason, while the record says failed. The call's line takes the `Failed` tag and the closed group's summary names it. |
| Order | Failed, needs you, running (in transcript order of their calls), lost contact, finished. |
| Several at once | One line each up to three running lines, then "and N more running", which opens the rest. Failed and needs-you lines do not count toward the three. |
| Opening a line | In place: the child's latest group (closed), any failure, and its live line, drawn by the section E renderers. Then "Open tracer", which goes to that worker. A follow-up opens to its text and status with origin. Source is last, as everywhere. |
| Elapsed time | A delegated worker's first turn: from `Worker.created_at`, monospaced. Nothing else has a start time (SVC), so nothing else shows one. No timer while disconnected. No client-side guess. |
| Regular | All of the above. |
| Compact (wall tile) | Failures, needs-you, two running lines, then the count. |
| PiP | Every failure, then one count line: "4 running, 1 needs you". It opens the stack. |
| VoiceOver | The stack is a group: "Background work, 6 jobs, 1 failed". A finish or failure is announced once, politely. |

Components: `BackgroundJob` (value: job kind, record ID, state, evidence origin), `BackgroundJobLine` (molecule, reuses `PrettyLiveLine` and `ActivityFailureLine`), `BackgroundStack` (organism). No new tokens.

## H. Edge cases

Every row of the first two tables in [pretty-conversation-edge-cases.md](pretty-conversation-edge-cases.md). Mockup: the "Edge cases" panel. The ACP features in that file's third table are not designed.

How to read "Data needed":

- **On the event** means the console event carries it today. A console event holds `kind`, `tool_id`, `name`, `phase`, `text`, `commander_input` and a bounded `acp` reference (kind, message ID, content type, MIME type, item count, mode, usage). Nothing else.
- **In scoped history** means the full ACP update is kept for the worker's source inspector (`internal/acpprocessor/history.go`), but Pretty does not receive it. Decision 8 moves it onto the event.
- **Not read** means I found no reader for that record type in `internal/provider` or `Sources`.
- A row with no data shows its fallback. It never shows a guess.

| Case | Sentence or component | Running / finished / failed | Grouping | Data needed |
|---|---|---|---|---|
| ACP tool content `diff` | The Change renderer (E) in the opened edit line. Counts beside the sentence | Editing *file* / Edited *file* `+3 −1` / Couldn't edit *file* | Folds. The diff shows when the line opens | SVC: in scoped history. Fallback: "The provider sent no diff for this edit." |
| ACP tool content `terminal`, `terminal/*` | The Terminal output renderer (E); exit state as lamp and word | Running `command` / Ran `command` / `command` failed, exit state | Folds; a failure does not | SVC: in scoped history. Fallback: the result text as today |
| ACP tool `locations` | "Open at line *N*" action in the opened file line | none | No change | SVC: in scoped history. Fallback: no action |
| ACP tool `kind` | Picks the verb for a tool Commander does not know: read, edit, delete, move, search, execute, think, fetch, switch mode. The object is the ACP title as sent. `other` or no kind: "Used `tool`" | Reading … / Read … / Couldn't read …, and so on per kind | Summary uses the kind's phrase only when the object is a path from `locations`; otherwise "used N other tools" | SVC: in scoped history |
| ACP content blocks: image, audio, resource, resource link (results and replies) | Attachment row: thumbnail, native audio control, link row with name and size, or quoted text for a text resource | In a reply: part of the prose. In a result: inside the opened line; the sentence gains an `image` or `audio` tag | A reply block breaks the group, as prose does. A result folds with its call | On the event: content type, MIME type, a non-data URI. The bytes are blanked for typed content (`typed.go` sets `data` to ""). SVC: the bytes or a reference. Fallback: "Image (image/png). Commander did not keep it." |
| ACP stop reasons | **End-of-turn line**, last item of the turn. `max_tokens`: "Stopped: reached the output limit". `max_turn_requests`: "Stopped: reached the request limit for one turn". `refusal`: "The model declined to continue". `cancelled`: "This turn was cancelled". `end_turn`: no line | none | Never folds. Attention ink for the first three, secondary ink for cancelled | The service holds `control.last_stop_reason` and each follow-up's `stop_reason`. No Swift type decodes either. Needs the Swift decode. Tying it to a turn in the transcript: not verified |
| ACP permission option kinds | Request form. Order: allow once, allow always, reject once, reject always. Allow once is primary. Labels are the provider's, exactly. One line under an always choice: "An always choice also answers later requests of this kind." | none | Never collapsed | SVC: `QuestionChoice` is `{id, label}`; the kind is dropped where choices are built (`acp.go`, `acp_v2.go`). Fallback: the provider's order and labels, first choice primary, no "always" line |
| ACP `elicitation/create`, `elicitation/complete` | `ElicitationCard`, `ElicitationFieldControl` and `ElicitationDecisionBar`, restyled as a request-form block: who asks, the message as prose, the schema's fields or the link, then Submit, Decline, Cancel | After the reply, a line: "Answered a form" / "Declined a form" / "Cancelled a form" | Never collapsed while pending | None for the card: `Elicitation.swift` already models form and URL modes, field kinds, validation and the reply. On only with `AGENT_COMMANDER_ACP_ELICITATION=1`, for local workers. The after-reply line needs a transcript record: not verified |
| ACP `plan_update`, `plan_removed` | The checklist card, updated in place. Removed: the card becomes the line "The plan was removed" | none | The card stands alone | SVC: the event text is "[ACP plan_update]" with no entries; only `plan` carries a count |
| ACP `notice` | Notice line: the title as sent | none | A warning or error stays visible in attention ink. Any other notice folds as a quiet line | On the event: the title, when `AGENT_COMMANDER_ACP_SESSION_ACTIVITY=on`. SVC: the level. Fallback without a level: stays visible |
| ACP `compaction_update`, `compaction_summary_chunk` | **Compaction divider**: a rule with "Conversation compacted" and "Show the summary". Nothing above it is removed or dimmed | Live line "Compacting the conversation" / the divider / failure line "Couldn't compact the conversation" | Breaks the group | On the event with the same switch: one row per compaction that updates in place, and summary chunks as text. Status values: not verified |
| ACP `subagent_update`, child permission declined | Background job line (G). A declined child permission is a failure line: "A child session's request was declined by Commander policy" `Blocked` | As section G | As section G | SVC, as section G: the event is the text "Provider child session" with an optional title and no ID |
| ACP `session_message`, `session_message_chunk` | **Message line**: "Message from *sender*", then the text quoted. Drawn with the report block's rule | none | Breaks the group, as prose does | On the event: chunk text and message ID. SVC: the sender. Fallback: "Message from another session" |
| ACP `prompt_suggestions_update` | **Suggestion chips** above the message box. A chip fills the box; it does not send. Each update replaces the chips; sending clears them | none | Not in the transcript | SVC: the event carries the count only. The texts are in scoped history |
| ACP `available_commands_update` | The quiet line, unchanged. A composer command menu is a new feature and is not designed here | none | Folds | On the event: the count |
| ACP history gap | Gap row: "Some history is missing here", with the provider's reason when sent. Hollow dot | none | Never folds; breaks the group | The gap observation is kept on the history record, and `ConversationActivity.isRoutine` already keeps a gap note visible. The exact text Pretty receives: not verified |
| Failed results by cause | Four entries in the known-denial table. Hook blocked: `Blocked`, "A hook blocked this." User declined: `Blocked`, "You declined this." Timed out: `Failed`, "Timed out." Interrupted: `cancelled`, "Interrupted." | Failure line, as today | Never folds | The exact provider phrases. The inventory counted record types and read no text, so each entry waits for a phrase from a real record |
| API error | Failure line with no tool: "The model request failed", then the provider's first sentence | none | Never folds | Not read |
| Compaction boundary and summary (Claude, Codex) | The compaction divider above | As above | Breaks the group | Not read from the Claude journal. Codex: not verified |
| Turn duration; turn aborted | The end-of-turn line: "Worked for 3m 12s" in secondary ink; "Stopped" for an aborted turn. One end-of-turn line per turn; a stop reason wins over a duration | none | Never folds | SVC: no event carries a time or duration. No client-side guess |
| Agent-to-agent messages and spawning | `SendMessage`, `send_message`: "Sent *name* a message". `Agent`, `spawn_agent`: "Started a child agent: *description*" and a background job line. `followup_task`: "Sent a follow-up task". `wait_agent`: "Waited for *name*" | Sending … / Sent … / Couldn't send …, and so on | Folds. Summary: "sent N messages", "started N child agents" | SVC: the arguments (decision 8), and section G's child record for the job line. Fallback: "Used `tool`" |
| Question tools (`AskUserQuestion`, `request_user_input`) | **Choice card** in the request-form language: the question, each option with its description, checkboxes when several may be chosen. Answered: "Asked: "…"" then "You chose: …" | Asking / Asked: "…" / Couldn't ask | Never collapsed while pending | The runner keeps `question`; the options are SVC. Whether Commander can answer the provider's own question tool: not verified. If it cannot, the card is read-only and says "Answer this in the terminal." |
| Plan approval (`ExitPlanMode`) | Plan document: heading "Proposed a plan", the plan as Markdown in the report block. Approve and Reject come from the permission request form, by its request ID | Proposing a plan / Proposed a plan `approved` or `rejected` / Couldn't propose a plan | Never collapsed | SVC: the plan text is the call's input (decision 8). Fallback: "Proposed a plan" with the form |
| Waiting and scheduled work (`Monitor`, `CronCreate`, `sleep`, `wait`) | `sleep`, `wait`: "Waited". `Monitor`, `CronCreate`: "Started watching …" / "Scheduled …" `accepted`, and a background job line | Waiting / Waited / Couldn't wait | Folds. Repeats merge | SVC: arguments, and section G's record for the job line |
| Tool loading (`ToolSearch`) | Sentence only | Loading tools / Loaded tools / Couldn't load tools | Folds. Summary: "loaded tools" | On the event: the name |
| Deliverables (`Artifact`, `SendUserFile`, pull request links) | File or link card: name, kind, Open. "Published *title*", "Sent you *file*", "Opened pull request *number*". A link is taken from a known tool's result, never found by scanning prose | Publishing … / Published … / Couldn't publish … | Never folds: it is a result for the user | SVC: the arguments and full result (decision 8). Fallback: the sentence without the card |
| Hook messages | Quiet line: "Hook: *message*". A blocking hook or a hook error stays visible in attention ink | none | Quiet ones fold | Not read |
| Goal and task status | No line of its own. It feeds the checklist card or a background job line | none | none | Not read |
| Codex code-mode `exec` and `js` | `exec`: the shell sentence, "Ran `command`". `js`: "Ran a script" | Running … / Ran … / … failed | Folds as commands | Add both names to `ProviderTool`; it lists `exec_command`, not `exec`. The script text: SVC |
| Images in results | Thumbnail row in the opened line, through the existing `RecordDataURL`; the sentence gains an `image` tag | none | Folds with its call | Drawn when the result part still holds its data. The 16 KB cut removes it (decision 8). Fallback as for content blocks |
| Server-side tools (`server_tool_use`, advisor results) | A sentence as for any tool: the web search and fetch rows of table A, otherwise "Used `tool`" | As table A | As table A | Not read |

New components: `PrettyTurnEndLine`, `PrettyCompactionDivider`, `PrettySessionMessage`, `PrettySuggestionChips`, `PrettyDeliverableCard`, `PrettyGapRow` (all molecules, no new tokens). The choice card and the elicitation card are the restyled request form and `ElicitationCard`. Everything else reuses a section E renderer.

## Service changes this depends on

Section H lists its own data needs row by row.

| Change | What it unlocks | Without it |
|---|---|---|
| Record the `tool_call` for `commander_status` (run1 has results at sequence 1 and 4 with no call) | "Checked worker progress" | "Got a result whose call was not recorded" |
| A start time on each tool call event | Elapsed time on the live line | Live line with no time |
| Pass ACP plan entries (they exist in `internal/acpprocessor/typed.go`) | Checklist card | "Updated the plan: N items" |
| Keep the model's Bash `description` | "Created the task worktree" style titles | "Ran `command`" |
| Keep a non-secret summary of Commander arguments: `op` and `card` (board), whether `text` was sent (thread), file count and message (commit), worker count (integrate), target count (submit) | The specific sentences in table A | The fallback column |
| Keep the `TodoWrite` todos (`internal/provider/runner.go` keeps only question, name, path and pattern) | Checklist card on the older runner | "Updated the plan" |
| Keep `revision` and `tests` on a reported result | Revision and test lines under the report | Report text only |
| A record per provider child session and background command: ID, parent tool call ID, description, state, start and end time. Checked in code: `ClaudeProgress` holds only `phase` and `updated_at`; `parent_tool_use_id` is parsed in `internal/provider/runner.go` but only used to match partial blocks; the journal reader skips sidechain rows; nothing reads `run_in_background`. Over ACP, `subagent_update` becomes the text "Provider child session" with an optional title, and a scoped child update carries no ID | Lines for Claude subagents, background commands and ACP child sessions (section G) | Those jobs get no line. The parent's call reads as an ordinary finished call |
| Start and end times on follow-ups, integrations and network operations | Elapsed time on those lines | No time shown |

## D. Open questions

One numbered list for the whole proposal: [pretty-conversation-proposal.md](pretty-conversation-proposal.md#open-questions).
