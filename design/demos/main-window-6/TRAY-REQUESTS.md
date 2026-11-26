# Requests to the network session, from main window increment 6

Each of these needs a change in a `Multiplayer*` file, which the main-window session doesn't edit. Requests 1 to 8 of [increment 5](../main-window-5/TRAY-REQUESTS.md) are done (PRs #22 and #24) and the window uses them.

## Open

| # | Request | Where | Why | What the window does until then |
|---|---|---|---|---|
| 1 | **Expose the secret refusal's text to accessibility.** The well in `MultiplayerKnowledgeForm` that shows `draft.secretProblem ?? refusal` is an empty element to VoiceOver. Make the sentence one static text with its own label. | `MultiplayerTeamsViews.swift`, `MultiplayerKnowledgeForm` | Increment 5 defect 7. The live Share form is this view inside `MultiplayerKnowledgeHost`, so the window can't reach it. | Nothing. The refusal is read by sight only. |
| 2 | **Name the widest scope in a refused share.** When the relay answers a share with 403, `MultiplayerKnowledgeHost` shows "Couldn’t share <name>. Forbidden." It can add the limit from `me[server].knowledgeWidestScope`: "<server> lets knowledge reach a group at most." | `MultiplayerTeamsHosts.swift`, `MultiplayerKnowledgeHost.send`, or `shareKnowledge(_:on:)` | Increment 5 defect 9. The refusal's sentence is the host's own. | The window puts the limit in the inspector's footer beside the host ("studio lets knowledge reach a group at most."), read from `loadMe`. The window's own share path adds it to the refusal (`TeamsPagesContent.shareRefusal`). |
| 3 | **"Its 1 member loses".** `MultiplayerGroupPage`'s delete confirmation reads "Its 1 member lose every grant made to the group." Use "loses" for one member. | `MultiplayerTeamsViews.swift:715` | Increment 5 defect 10. | The window draws its own confirmation over the group page with the right verb, and passes `confirmingDelete: false`. The tray still shows the old sentence. |
| 4 | **Give the claim host's refusal to its caller.** `MultiplayerClaimHost.send` calls `model.claim`, so `onFinish` gets a result without the holder. Call `claimAnswer` and pass the `MultiplayerClaimRefusal` on, for example `onRefused: (MultiplayerClaimRefusal) -> Void`. The card host could do the same with `updateCardAnswer` and `completeCardAnswer`. | `MultiplayerTeamsHosts.swift`, `MultiplayerClaimHost`, `MultiplayerCardHost` | The Claims band marks the row that stopped a claim. With the host, the window never sees which one. | The row is marked only for a card claimed from the board, which is the window's own action and uses `updateCardAnswer`. A claim refused in the hosted form shows the host's sentence and marks no row. |
| 5 | **Offer Leave to a member, not the owner, in the tray's wording.** The relay refuses an owner who leaves ("the owner cannot leave workspace <id>"). The request for increment 6 said to offer Edit and Leave to the owner. | Plan and contract, not code | The window follows the relay. | Edit… is offered to the owner. Leave… is offered to a member who is not the owner. |

## Open, from issue #35

| # | Request | Where | Why | What the window does until then |
|---|---|---|---|---|
| 6 | **Build each link's label from `CommanderOpenRequest.landingCrumbs`.** `MultiplayerWindowLink.init(page:server:)` writes the crumbs for every page in its own `switch`. Replace that table with `request.landingCrumbs`, read from the request the same initializer already builds: `MultiplayerWindowLink(request: $0, crumbs: $0.landingCrumbs, item: item)`. Keep the item words ("this review") as they are. The property is not actor-isolated, so the initializer needs no change of isolation. Update the expectations in `MultiplayerOpenInWindowTests`. | `MultiplayerOpenInWindow.swift:76–111`, the `link(_:_:)` helper and its `switch` | Two labels are not where the router lands. A review's row reads "Agents › Runs" (line 93) and opens on Network › Hand-offs. Watch's and Control's rows read "Agents › Runs" (line 92); the window's breadcrumb there is "Agents › Workspace › Runs". The other pages agree today, but only because two tables were typed alike. | The window exposes `landingCrumbs` and tests it for every moved page (`CommanderWindowRouterTests.everyMovedPageNamesTheCrumbsItLandsOn`). The tray's rows keep their own words. |

## Answered in issue #26

1. Done. The secret refusal is one static text; its label is the heading, the reason and the advice (`MultiplayerKnowledgeForm.secretLabel`).
2. Done. `MultiplayerKnowledgeHost` reads `loadMe` itself and adds "<server> lets knowledge reach a group at most." to a refused share whose scope was wider than the server allows (`MultiplayerKnowledgeHost.refusal`). The host sees the reason without its HTTP status, so the rule is the scope, as in the window.
3. Done. "Its 1 member loses every grant made to the group." (`MultiplayerGroupPage.deleteQuestion`).
4. Done. `MultiplayerClaimHost` and `MultiplayerCardHost` take `onRefused: ((MultiplayerClaimRefusal) -> Void)? = nil`, called before `onFinish`. They call `claimAnswer`, `updateCardAnswer` and `completeCardAnswer`.
5. Confirmed. The tray's workspace page offers neither Edit nor Leave, so no tray wording is wrong. The increment 5 request that said the header gives both to the owner is corrected in [main-window-5/TRAY-REQUESTS.md](../main-window-5/TRAY-REQUESTS.md): Edit for the owner, Leave for a member who is not the owner.

## No longer needed

- **The policy host without its Cancel** (increment 5 request 8). `onCancel` is optional now. The live Admin page no longer shows `MultiplayerPolicyHost`: it draws the policy form and the member and device lists itself, from `loadPolicy` and `loadRoster`. The host stays available through `TeamsHosted.policy`.
