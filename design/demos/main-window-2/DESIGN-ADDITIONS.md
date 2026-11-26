# Proposed additions to DESIGN.md

`DESIGN.md` was not edited. Increment 2 uses what is below. Approve, change or reject each one; the text is ready to paste. Nothing here repeats the increment 1 additions (page title, control type, page inset, surface roles, material, tone lamp).

The sizes are in `ShellLayout` (`ShellMolecules.swift`) and `NeedsYouLayout` (`NeedsYouPage.swift`).

## 1. Section 2, Spacing and size: the shell

Add these rows:

```markdown
| Sidebar width | 224 pt |
| Sidebar row height | 28 pt |
| Mode rail width | 48 pt |
| Mode rail cell | 32 pt square, 18 pt icon |
| Context list width | 196 pt |
| Place mark | 18 pt |
| Corner count | 14 pt |
| Toolbar band | 52 pt |
```

## 2. Section 3, Atoms

Add these rows:

```markdown
| Count | A place's count in `label`, on `hair`. A hot count is filled `attention` with `onAccent` ink. A figure such as "2/3" takes the count's place and is never hot. |
| Place mark | An 18 pt symbol in `secondary`, or `foreground` when selected. A project or workspace is one letter in `focus` on a square mark. |
```

## 3. Section 3, Molecules: navigation

Add these rows:

```markdown
| Place row | A place mark, the title in `body` and a trailing count, 28 pt high. The selected row is filled `selection` with the 2 pt `focus` leading marker. Hover tints it 6%. Each of the first nine rows has a ⌘ number shortcut, named in its tooltip. |
| Group heading | The group's name in `heading` and secondary ink. A group that folds is a button with a chevron; while folded it shows its hot count beside the name. |
| Mode cell | A 32 pt square cell with an 18 pt icon. The selected cell is filled `selection` with the leading marker. A hot count sits on the top trailing corner at 14 pt. Each cell has a ⌘ number shortcut. |
| Inbox cell | The pinned inbox: a tray mark, "Needs you" in `name`, one `sub` line saying where requests come from ("3 from your workers, 4 from the network") and the total as a `figure` in `attention`. While something waits it is filled `attention` at 12% with a 45% edge. Empty, it has a `hair` edge and says "Nothing is waiting for you" beside an `on` lamp. Selected, it looks like a selected place row. |
| Profile row | A round avatar, the person's name in `name`, and a lamp with the presence word in `state`. The whole row opens the presence choices in a native menu. |
| Toolbar readouts | A status strip sized for the toolbar: `label` over a `data` value, cells split by hairlines on the well inside one hairline frame. `servers` shows "2/3" with a lamp (`on` when all answer, `busy` and `attention` ink when some do, `error` and `failure` ink when none do) and opens Servers. `presence` shows the lamp and word, has a chevron beside its label and opens the presence choices. |
```

## 4. Section 3, Molecules: inbox

Add these rows:

```markdown
| Origin cell | Who asks, at a fixed 196 pt so every request starts on one line. A local worker is a 28 pt square mark, its name in `data` and its host in `fingerprint`. A network request is the server's swatch, the friend's round 28 pt avatar, the handle in `data` and the server in `fingerprint`. |
| Kind tag | question, approval, access or friend, as a badge in `label` beside the request's title. |
| Clock label | Right-aligned in `data` over a `fingerprint` word: the time left ("4:12 left", `working`, then `attention` under five minutes) or the wait ("6m waiting"). |
| Reply field | A field box under a question's row, then Cancel and a primary Send. Send is off while the field is empty. Return sends and Escape cancels. |
```

Change the Decision row, Load note and Outcome well rows to say:

```markdown
| Decision row | A request with Deny and Approve, Decline and Review, Decline and Accept, or Reply for a question. The primary answer is the last cell. The text opens the full review. |
| Outcome well | A well holding a state label that replaces a verb strip once its action is done, then fades out: Approved, Accepted and Replied in `working`, Denied in `failure`, Declined in neutral, In review in `focus`. |
```

## 5. Section 3, Organisms

Add after the tray's list:

```markdown
The main window adds a grouped sidebar, a mode rail with a context list, a Needs you sidebar and the Needs you row.

A Needs you row is an origin cell, a hairline, the request (title in `name` with its kind tag, one or two lines in `sub`), a clock label and a verb strip. Rows share one panel and are ruled off by hairlines.
```

## 6. Section 4, Layout patterns

Replace the **Places** line with:

```markdown
- **Places:** a tab bar or a sidebar of places. Each place shows a count. A sidebar is docked: a `well` against the window's leading edge with a hairline against the canvas. Its groups are ruled off by hairlines and headed in `heading`. Places that are always needed (Hosts, Settings) sit at the foot under a hairline.
- **Mode rail:** a 48 pt rail of mode cells with Settings at the foot, a hairline, then a 196 pt context list headed by the mode's name in `title` with its hot count. The context list holds every page of the mode.
- **Needs you first:** the inbox cell is pinned above the groups. The queues it stands in for (Attention, Approvals, Friend requests) are not listed. A count is never shown twice: a total that includes the inbox leaves those queues out.
- **Window toolbar:** the app's name and a breadcrumb at the leading edge; toolbar readouts at the trailing edge. Presence moves to the sidebar footer where the sidebar has a profile row.
```

Add after **Order of urgency**:

```markdown
- **Needs you order:** a request with under five minutes left comes first whatever its kind; then the person's own stopped workers, longest wait first; then network approvals, soonest end first; then access requests; then friend requests. A decided row keeps its place while its outcome shows.
```

## 7. Section 5, Behaviour: Keyboard

Replace the Keyboard line with:

```markdown
- **Keyboard.** Places switch with ⌘1, ⌘2, ⌘3 and so on, down the visible rows of a sidebar (the pinned inbox is ⌘1) or down the modes of a rail. Rows past the ninth and the foot places have none. Every custom control is reachable by Tab.
```

## Black glass, for the record

Black glass uses the same components through its own tokens: the sidebar floats as the glass sheet of today's navigation rail, groups are separated by space, not rules, the selected row has the rounded selected fill and outline with no marker, and a hot count uses the highlight fill. No new black-glass values were added.
