# Requests to the network session, from main window increment 5

## Done, and adopted

PR #13 gave the Teams model reads the caller owns, actions that name their target, and hosts with `scrolls:`. PR #14 gave `apply` a result per artifact, removing a server by value, `share.resource(forWorker:)`, the zoom's `footerTitle:` and `allowsSuggestion:`, and themed tray atoms. The window uses all of them. Nothing of those requests is left open.

## Still open

Each is a read or a field the Teams pages show as demo only today.

| # | Request | Why | What the page does until then |
|---|---|---|---|
| 1 | **Members and devices of a relay, for its admin.** A caller-owned read per server: members with `handle`, `suspended` and `admin`; devices with `id`, `name`, `owner` and `lastSeen`. | Admin can then list people and devices and put Suspend…, Unsuspend and Revoke… on each row. | The live Admin page is the policy host alone, which moderates by a typed handle or device ID. |
| 2 | **A workspace's combined view.** A caller-owned read per workspace: for each member, their workers with `name`, `harness`, `model`, `state`, `branch` and `checks` (`passed`, `failed`, `running`). | The Combined view band is in the plan and has no read. | The live band lists the group's members and the agents that hold a claim, with what each holds. |
| 3 | **A workspace's owner as a handle.** `ownerHandle` beside `owner`, as groups have. The same for a knowledge item's `owner`. | The page can say who owns a workspace and whose Mac runs its queue, and name who shared an item. | The owner isn't shown. An item's owner shows only when it is a handle the window knows. |
| 4 | **Enrolled commands on a host you lend.** `capabilities.commands` on your own `host` resources, as friends' directory entries carry. | "You lend" can list what each of your hosts runs. | The column is empty for a live host. |
| 5 | **The policy's knowledge limits for a member.** `knowledgeDefault` and `knowledgeWidest` in what a member can read (the contract puts a policy summary in `GET /v1/info`). | The share form can say how widely this server lets knowledge travel before the relay refuses. | Only the preview says it. Live, the relay's refusal says it after the fact. |
| 6 | **Leave and edit a workspace.** Calls that name the workspace. | The plan gives the workspace header these for its owner. | Not offered. |
| 7 | **A holder in a refused claim's result.** The claim ID or the holder as a field of the refusal, not only in its sentence. | The Claims band can mark the row that stopped the claim when the network's host sends it. | Only the window's own claim form marks it, by finding the holder in the sentence. |
| 8 | **The policy host without its Cancel**, or an `onCancel` that is optional. | On a page that is the host's home, Cancel has nothing to close. | The button does nothing there. |
| 9 | **An answer that outlasts the hold while the relay still lists the request.** If the relay keeps listing a denied approval, `answer(for:on:)` is nil again after 2 s. | The row then reads as waiting, with its verbs and countdown. | The window shows what the network says. |
| 10 | **Steady the hold test.** `MultiplayerWindowCheckTests.anAnsweredRowIsHeldForTheLiveHoldThroughReadsAndNavigation` failed in two of five full runs on this branch and passes alone. | It polls every 150 ms and the scripted helper's first approvals reply can be used up before the check. | — |
