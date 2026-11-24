# macOS multiplayer tray verification

On 2026-11-23, Computer Use exercised the native network panel from a signed copy of the pilot app with a distinct bundle identifier. The debug review window hosted the same SwiftUI panel as the menu bar. Its disposable helper returned fixture identities and recorded the tray commands locally. The screenshots show the panel at its native width in that review window.

| Step | Observed state |
| --- | --- |
| [Signed out](signed-out.jpg) | The panel offered browser sign-in. |
| [Signed in](online.jpg) | The panel showed alex online and a pending request from sam. |
| [Friend accepted](friends.jpg) | Sam appeared in Friends with no access shared. |
| [Grant review](grant-review.jpg) | After adding Review worker, the owner selected seven uses and eight hours. The review named the friend, worker, action, exact expiry, existing tool permissions and provider quota. |
| [Grant confirmed](granted.jpg) | The panel showed the grant and its limits after the helper confirmed. |
| [Revoke review](revoke-review.jpg) | A separate confirmation identified sam, the worker and the action. |
| [Revoked](revoked.jpg) | Sam remained a friend and the worker remained enrolled. The list of granted access was empty. |

The scrollable share editor exposed the quota field, stepper, duration picker and Review button through macOS Accessibility. A success notice from the previous action remained visible until dismissed or superseded. Browser OAuth, live relay delivery and provider calls require their own integration checks.

## Native model and live relay

On 2026-11-24, a Swift integration test opened the tray's `MultiplayerModel` and used `MultiplayerProcessHelper` with the executable extracted from the universal Mac ZIP. Alice and Bob had enrolled through a simulated browser on two independent Go relay edges. The relay used real PostgreSQL and JetStream in disposable Docker containers. The worker returned deterministic fixture output.

The model read Bob's incoming request, accepted it and refreshed to show Bob as a friend. It reviewed and confirmed an eight-hour, seven-use `agent.ask` grant for one worker. Bob received a signed result and the worker recorded one turn. The model then revoked the grant and refreshed to show Bob still as a friend. The relay refused Bob's fresh request and the worker's turn count stayed at one. Teardown removed the isolated data stores and device processes.

The desktop connection expired during the click-through attempt. This run verified the open panel model, its bundled helper and the relay responses. The screenshots above show the earlier visual review with a scripted helper. Live browser sign-in and a visual click-through against the live relay are still open.
