# Two-person multiplayer relay pilot

## Acceptance

Two independently signed-in tray clients can use different public edges, find an exact handle, accept a friendship, share a named local agent or repository with explicit permissions, and revoke access. A coordinator can ask an authorized peer for help on an issue, exchange results, and use its owner's repository capability to commit, push and close that issue. The pilot exercises both directions, duplicate requests, reconnects and revocation. A live test requires a reachable HTTPS endpoint, two OIDC accounts and an explicitly selected GitHub repository. Use disposable local equivalents for automated verification.

## Implementation sequence

1. **Identity and presence.** Add a separately buildable Go multiplayer binary. Open the system browser for OIDC authorization code with S256 PKCE. Bind enrollment to a challenge for the presenting client certificate and match the signed ID token nonce. Pin a device's public signing and encryption keys to its issuer and subject. Protect device keys in the OS credential store. Clients connect outbound to any TLS edge behind layer-4 ingress. Short-lived device sessions and monotonically increasing PostgreSQL lease generations fence stale sessions. Presence expires if the client stops renewing.
2. **Friendships and resources.** Support exact-handle discovery, inbound friend requests, accept, remove, and directional grants. Publish opaque resource IDs, human-readable names and supported actions. Scope every grant to owner, recipient, resource, permitted actions, expiry and applicable use limit. Enforce grants at submission and again at claim. Keep provider and GitHub credentials on their owner's device.
3. **One-to-many delivery.** Freeze the recipients of a submission and record one encrypted child and outbox intent per target in the same transaction. Authenticate the signed content at the target. Private NATS JetStream carries delivery IDs. Interchangeable dispatchers wake the edge serving each device. Reconnecting clients recover pending children from the authoritative store. Claims must match the current session and grant. Record uncertain external outcomes and reconcile by operation ID.
4. **Local execution and coordinator tools.** The device dispatches only registered, versioned action types. An owner maps resource IDs to a local worker or checkout. Repository adapters accept structured issue, branch, commit and push operations for that repository; use owner-local credentials. Provider sharing authorizes work through the local agent with bounded usage. Expose discovery, submission and receipt lookup to coordinators using their scoped MCP identity.
5. **Tray and deployment.** Claude Opus owns the native menu-bar interface. Provide sign-in, connection state, friend requests, grants, visible resources and revocation through the local device agent. Package the agent with the tray. Supply self-hosted pilot configuration for PostgreSQL, authenticated private NATS/JetStream, OIDC, and two TLS edges under one hostname.
6. **Acceptance run.** Use separate device keys and user identities, real PostgreSQL and JetStream, two edges, and an isolated Git remote and GitHub API fixture. Observe create/accept/revoke, three addressed deliveries, reconnect fencing, duplicate suppression, and a two-coordinator issue-to-push-to-close workflow. Record actual commands, results and any live-only gates. Run the native workflow through Computer Use and exercise optional real GitHub writes only on the designated repository.

## Extension boundaries

The design-patterns plugin's Recipient List, Competing Consumers and Transactional Outbox separate recipient selection, dispatch and durable publication. Fencing Token applies at route renewal and claim. Idempotent Receiver and Correlation Identifier bind retries to the original operation. Use a Strategy for audience selection, an Adapter per local capability and a Message Dispatcher for versioned actions. Policy remains in the core around every adapter. A second provider should require registration and its own contract tests. Adding a provider must never expand existing grants.

The existing single-host reverse proxy and its worker-level OAuth authorization keep their existing protocol. The multiplayer service uses a separate API and release entry point. During the pilot, durable ID notifications can wake a session over NATS while the recipient retrieves its sealed child over HTTPS. This avoids direct edge-to-edge payload streaming for bounded work items. See the [architecture and failure scenarios](MULTIPLAYER-RELAY.md) and the [pattern decisions](PATTERN-DECISIONS.md).

Browser sign-in follows [RFC 8252](https://www.rfc-editor.org/rfc/rfc8252). Broker consumers use the [JetStream pull-consumer contract](https://docs.nats.io/learn/jetstream/pull-consumers). A repository-scoped GitHub App installation is one way to supply the owner's short-lived [GitHub credentials](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-an-installation-access-token-for-a-github-app).

## Resolve the live pilot blockers

The local rehearsal passed with disposable identities and a Git remote. Work through these steps in order. Use the private GitHub prerelease for this pilot. Developer ID signing and notarization are deferred to a later release. [Readiness audit](verification/multiplayer-pilot/README.md#november-24-readiness-audit)

1. **Verify Cloud SDK access.** The deployment operator signs in using the authorized Google account. Pin subsequent commands to that account and the dedicated pilot project. Verify the project ID and read its billing status. **Pass** when both reads succeed under the operator identity. [Cloud SDK sign-in](https://docs.cloud.google.com/sdk/gcloud/reference/auth/login)

   ```sh
   pilot_operator='operator@example.com'
   pilot_project='bytedesk-agent-commander-pilot'
   gcloud auth login "$pilot_operator" --force --no-activate --no-launch-browser
   gcloud projects describe "$pilot_project" --account="$pilot_operator" --format='value(projectId)'
   gcloud billing projects describe "$pilot_project" --account="$pilot_operator" --format='value(billingEnabled)'
   ```

2. **Register Google sign-in for both participants.** Confirm the exact Google accounts they will use. In the dedicated project's Google Auth Platform, complete branding and create a **Desktop app** OAuth client. Use External testing and list both accounts if a participant is outside the project's Workspace. The app uses `openid` and `email` with PKCE and a loopback callback. Save the client ID and the two allowed account addresses for step 6. Keep the matching Desktop OAuth JSON in private storage so the operator can provision both Macs for step 7. **Pass** when the project has a Desktop client ID and both accounts are eligible. Verify actual sign-in in step 7. [Pilot project OAuth clients](https://console.cloud.google.com/auth/clients?project=bytedesk-agent-commander-pilot) · [Google consent setup](https://developers.google.com/workspace/guides/configure-oauth-consent) · [Desktop OAuth](https://developers.google.com/identity/protocols/oauth2/native-app)

3. **Verify the private Mac prerelease.** Confirm both Macs run macOS 26 or later. Download the universal macOS ZIP and `SHA256SUMS` from the private release, verify the archive, and open the extracted app. Use `v0.1.0-pilot.3`, which includes the Google Desktop OAuth exchange and relay sign-out fixes. **Pass** when both participants can open the verified private build. [Private prerelease](https://github.com/nscaledev/agent-commander/releases/tag/v0.1.0-pilot.3) · [Later notarized distribution](#build-the-universal-macos-archive)

4. **Designate the GitHub test repository.** Use the private Agent Commander repository and its [disposable acceptance issue](https://github.com/nscaledev/agent-commander/issues/1). Confirm its branch rules allow the dedicated `commander-share/<resource-id>` branch. Check that the owner's local checkout points to the selected GitHub repository. **Pass** when the owner has confirmed the checkout, test issue, and individual read and write capabilities for the pilot. Create the short-lived, repository-scoped token with Contents and Issues write at the start of step 7. [GitHub token setup](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens) · [GitHub permission reference](https://docs.github.com/en/rest/authentication/permissions-required-for-fine-grained-personal-access-tokens)

5. **Prepare the relay on Fabric GKE.** Use the `agent-commander` namespace on `fabric-prod` in `fabric-512915/us-west1`. Stage the app through the Fabric GitOps workflow and use its production promotion review. **Pass** when Flux reports the intended revision ready and two relay edge Pods, three JetStream members and PostgreSQL are healthy, with persistent storage and an isolated backbone. [Fabric GKE deployment](#fabric-gke-deployment)

6. **Publish DNS and bring up mutual TLS.** Point `srv01.agentmux.bytedesk.ai` at the dedicated regional load balancer IP using a Cloudflare **DNS-only** A record. Issue a publicly trusted certificate for the hostname using ACME DNS-01. Use the tested Linux image and supply `prepare.py --public` with the certificate chain, key, Desktop client ID, and both email allowlist entries. Mount the generated credentials as workload-scoped secrets. **Pass** when a client-certificate probe gets HTTP 204 with either edge unavailable in turn, a probe without a certificate fails, and PostgreSQL and NATS are reachable solely on the private backbone. [Credential preparation](../multiplayer/deploy/README.md#prepare-the-host) · [Cloudflare DNS-only records](https://developers.cloudflare.com/dns/proxy-status/) · [ACME DNS-01](https://letsencrypt.org/docs/challenge-types/#dns-01-challenge)

7. **Verify the complete workflow on two Macs.** Follow the [first-session checklist](#first-session-on-two-macs). After signing in, the repository owner enrolls the checkout and enters the token directly in their tray. Start with read access, then grant the individual writes. Confirm exact-handle discovery, mutual friendship, separate grants in both directions, coordinator messages, a worker result, the pushed SHA, and the closed test issue. Revoke one grant and verify the next operation is refused while the other grants still work. **Pass** when both participants see the expected state and GitHub shows the exact pushed revision and issue closure.

## Fabric GKE deployment

The pilot uses `fabric-prod` in `fabric-512915/us-west1`. The cluster has AMD64 nodes, GKE Dataplane V2, CSI persistent disks, Workload Identity, and a ready `gcp` external secret store. The Fabric production application overlay assigns the `fabric` namespace, so give Agent Commander a dedicated Flux Kustomization that owns `agent-commander`. Promote the signed GitOps bundle through the `production` environment, which requires reviewer approval. [Fabric deployment repository](https://github.com/nscaledev/nos-fabric-deploy) · [Production promotion workflow](https://github.com/nscaledev/nos-fabric-deploy/actions/workflows/promote.yml)

- Import the checksum-verified `commander-relay-pilot-linux-amd64.tar.gz` from the private prerelease into the Fabric workload registry and reference its registry digest. Deploy two edge Pods on separate nodes, three JetStream members with separate volumes, and PostgreSQL with a dedicated volume. Use the existing certificate-generation boundaries for named edge and broker identities. Restrict the Kubernetes service accounts and mount workload-specific material from the secret store. [Private prerelease](https://github.com/nscaledev/agent-commander/releases/tag/v0.1.0-pilot.2)
- Use a dedicated external TCP `LoadBalancer` Service on port 443 with `loadBalancerClass: networking.gke.io/l4-regional-external` and a regional static IP. The GKE load balancer passes TLS through to the Go edge. Keep PostgreSQL and JetStream on internal Services with NetworkPolicies that limit access to the required pods and ports. Allow the edges to reach Google discovery and signing-key endpoints. [GKE passthrough load balancers](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/service-load-balancer) · [GKE NetworkPolicy](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/network-policy)
- Provision a namespaced ACME DNS-01 issuer with Cloudflare zone-scoped credentials, or supply an approved certificate through the secret store. Deploy the DNS-only A record after the dedicated IP is assigned. Verify external TLS, then exercise one-edge-at-a-time outage and reconnection. Provision the private Desktop OAuth JSON separately on the two Macs. [Mac OAuth provisioning](../multiplayer/deploy/README.md#prepare-the-host)

## Relay VM estimate

The proposed configuration uses one on-demand `e2-medium` in Iowa (`us-central1`), a 30 GiB balanced persistent disk, and one attached Standard Tier regional IPv4 address. The estimate uses 730 hours and 10 GiB of outbound traffic per month for two participants, at Google Cloud list prices checked November 24, 2026.

| Item | Estimated monthly cost in USD |
| --- | ---: |
| `e2-medium` at $0.03350571/hour. [Compute pricing](https://cloud.google.com/products/compute/pricing/general-purpose?hl=en) | $24.46 |
| 30 GiB balanced persistent disk at $0.10/GiB-month. [Disk pricing](https://cloud.google.com/products/block-storage) | $3.00 |
| Attached IPv4 at $0.005/hour, before any free usage. [Network pricing](https://cloud.google.com/vpc/network-pricing) | $3.65 |
| 10 GiB Standard Tier egress. The first 200 GiB per month are shared across the billing account. [Network pricing](https://cloud.google.com/vpc/network-pricing) | $0.00–$0.85 |
| **Estimated total** | **$31.11–$31.96** |

Taxes and backup storage are additional. For example, 5 GiB of standard snapshot storage adds about $0.33 per month at Iowa list prices. A reserved but unattached address costs $0.01/hour. Reprice if the region, disk size, or traffic assumptions change. [Disk pricing](https://cloud.google.com/products/block-storage) · [Network pricing](https://cloud.google.com/vpc/network-pricing) · [Pricing calculator](https://cloud.google.com/products/calculator)

## First session on two Macs

The local Docker rehearsal runs three isolated users through login, friendship, scoped sharing and a real Git push. Run `make test-multiplayer-docker` to repeat it. [Verified outcomes and connectivity diagrams](verification/multiplayer-pilot/README.md)

Deploy the edges behind the pilot hostname, `srv01.agentmux.bytedesk.ai`. Use a publicly trusted certificate and TCP passthrough to the edges. Configure `https://accounts.google.com` and the pilot's **Desktop app** client ID on both edges. Pass `--allow-email` once per participant when preparing the deployment. Each Mac signs in through the system browser and keeps its own device keys and renewable credential in Keychain. The Cloud SDK login used by an operator to create the OAuth client is separate from either participant's tray login. [Deployment instructions](../multiplayer/deploy/README.md)

The live checklist requires a Fabric GKE origin, a Cloudflare DNS-only record pointing to its TCP load balancer, and a publicly trusted certificate for the relay hostname. Register the Google OAuth client with an audience that includes both pilot accounts. Confirm the two Macs can sign in, that each shows the other online after accepting the friendship request, and that owner-scoped grants control both directions. Use a designated repository and disposable issue for the first GitHub write. The owner can use a fine-grained token limited to that repository with **Contents** write and **Issues** write. [GitHub token permissions](https://docs.github.com/en/rest/authentication/permissions-required-for-fine-grained-personal-access-tokens)

1. On macOS 26 or later, use the private `v0.1.0-pilot.3` prerelease and install the matching Google Desktop OAuth JSON in each device's private state directory. The app bundle contains both local helpers. Open Agent Commander, then open its network panel in the menu bar. [OAuth fix](https://github.com/nscaledev/agent-commander/commit/5e4da8d83b74f9a0243f9defcbb030694022d7d9) · [Mac OAuth provisioning](../multiplayer/deploy/README.md#prepare-the-host)
2. Sign in, select your invited Google account in the browser, and choose a handle on each Mac. Search for the other person's exact handle, send a friend request, and accept it on the other Mac. Accepted friends can see each other's presence. [Google account chooser](https://developers.google.com/identity/openid-connect/openid-connect#authenticationuriparameters)
3. On each Mac, register the local agent or repository to share. For an agent, use a Commander worker or active coordinator ID. A worker must support follow-ups and have its input held for a shared question. For a repository, select its local GitHub checkout. Supply a repository-restricted credential in the owner's panel for GitHub actions. Choose the specific friend, capability, expiry and use limit for each grant.
4. Share each coordinator's `agent.message` capability in both directions. Use `commander_network_discover` to find shared IDs and actions. For an action listed on the selected resource, use `actionContracts[action].payloadSchema` to build the `commander_network_submit` payload. Use an empty object for actions with no arguments. One coordinator can send a message about an issue, and the other can read it with `commander_network_inbox` and reply under its own directional grant. The inbox holds the most recent 32 messages and identifies the peer who sent each one. A worker's `agent.ask` uses its owner's harness and returns the addressed turn's answer. [JSON Schema object reference](https://json-schema.org/understanding-json-schema/reference/object)
5. For a shared repository, start with `issue.read` and `git.head`. Submit a `git.commit` with the expected head, changed file contents and commit message. Use the returned commit SHA for `git.push`. The owner adapter pushes to `commander-share/<resource-id>`. Use `issue.comment` and `issue.close` when those separate permissions are granted. Requests for one or more recipients each need a stable submission ID. Poll `commander_network_receipt` for each child's status before advancing dependent work.
6. Revoke one grant and use a fresh submission ID to verify that the action is refused. A `denied` receipt means the accepted action lost its allowance before claim. The original submission stays denied even if the owner renews access. Close the tray session to go offline. An abrupt network loss ages out presence within 65 seconds.

Read a coordinator's current inbox with `commander_network_inbox({})`. To wait for subsequent notes, pass the last processed ID as `afterMessageId` and `waitSeconds` up to 10. An empty result means the wait timed out. If a cursor falls outside the retained window, the response returns the available messages with `truncated: true`. Deduplicate replayed messages by ID. The wait holds the active coordinator's tool call open. An authorized `agent.message` goes straight to that inbox without asking the operator to approve the note. The coordinator still owns delegation and any approvals for work it initiates. A stored note does not start a provider or confirm that a person read it. If a fresh run replaces the coordinator, register its new resource and grant the reply action again.

### Check the running app build

Upgrade the owner’s native app and bundled network helper. On the active local coordinator, grant **Check the running app build** separately from the note. For a coordinator enrolled before the upgrade, the owner’s grant sheet offers the action and the explicit grant refreshes that coordinator’s relay registration when needed. A prior note grant does not permit build queries. The capability uses the existing device envelope and works with older relays. Older apps provide no launch evidence.

Discover the granted `app.build` capability and submit a fresh operation with a random 32-character lower-case hex `nonce` and the current UTC RFC 3339 `issuedAt`. Read the signed outcome through `commander_network_receipt`. A result is current only with `buildEvidence: "verified"`. The receipt binds the peer and resource, and its evidence binds the exact nonce. A request or observation older than its 90-second window does not verify the current build. If the grant asks for approval, the owner has to answer within that window.

Compare `revision`, `tree` and `launchId` across fresh observations. The same launch ID identifies the same app instance, even if the service reconnected. A different launch ID and its kernel start time distinguish a relaunch. A dirty build may carry the expected Git revision. Treat its stamp as the reported source revision while preserving the reported dirty state. The request runs no command and never relaunches the app.


The agent resource shares the ability to request a bounded number of operations. The provider credentials stay on the owner's Mac, and one use is one operation. A model call's actual token count can vary. Each Mac's OS user is the local trust boundary for the owner socket and Keychain. Peers see the resource names, granted actions and replies the owner shares. Relays see routing metadata and encrypted envelopes. A first-time device key is trusted through the authenticated directory, and its signing and encryption keys are pinned locally for subsequent deliveries.

The pilot supports explicit one-to-many target lists. Named persistent groups, pooled token budgets measured in provider tokens, and multi-host database or ingress failover belong to later increments in the [relay architecture](MULTIPLAYER-RELAY.md).

## Hand off to an enrolled workspace

Upgrade the relay and both Macs. On the recipient's Mac, share an Agent resource for the existing workspace and choose a local coordinator run as its anchor. The anchor supplies the owner-selected checkout and provider. The workspace inbox remains available after that run ends. Leave **Auto-start** off to retain queued work until an eligible coordinator is available. Enable it to let the device start a managed workspace coordinator when none is running.

Give the paired workspace member the handoff, status, and result grants. Keep handoff approval set to **Ask** if the owner should approve each operation. The device persists the handoff while that approval is pending. Grant automatic admission for bounded work that may wake an idle coordinator without a separate owner decision.

Send a handoff from the existing shared resource. **Delivered** means the handoff was persisted on the recipient device. **Accepted** identifies a claimed coordinator turn. **Verified** requires a completed turn and matching evidence. For the first evidence type, provide the full expected Git commit in the handoff and refresh status or result to retrieve the matching observed revision. A completed turn with missing or different checkout evidence remains unverified.

## Read a failed repository receipt

The recipient device signs and encrypts a fixed recovery code in `result.code`. For `stale_revision`, read the current shared branch with `git.head` before preparing a revised change with a fresh submission ID. For `outcome_uncertain`, look up the original submission and check with the repository owner whether the external write took effect before submitting another write. The original submission ID can recover the receipt without repeating the action. Other failure codes report access denial, invalid requests, conflicts, or unavailable owner resources.

## Build the universal macOS archive

Run `make pilot-macos` with the macOS 26 SDK and the Go SDK archives pinned in `go.mod`. This produces `dist/Agent-Commander-Multiplayer-Pilot-macOS-universal.zip` for local testing. The build verifies signatures and Intel and Apple silicon slices in the extracted app and both helpers. It stages separately from the installed app and prints the archive's SHA-256.

For distribution to another Mac, the Apple Developer team prepares a Developer ID Application signing identity with its private key on the build Mac. An authorized operator can set up the `commander-pilot` Keychain profile with an Apple Account app-specific password. Enter it at the prompt. Use `history` to verify that the profile can reach Apple's notary service before building. [Apple Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/) · [Apple notarization credentials](https://developer.apple.com/documentation/technotes/tn3147-migrating-to-the-latest-notarization-tool)

```sh
security find-identity -v -p codesigning
xcrun notarytool store-credentials commander-pilot --apple-id 'operator@example.com' --team-id 'TEAMID'
xcrun notarytool history --keychain-profile commander-pilot
```

Run the build using the Developer ID Application name returned by `security find-identity`.

```sh
make pilot-macos CODE_SIGN_IDENTITY='Developer ID Application: Example (TEAMID)' \
  PILOT_NOTARY_PROFILE='commander-pilot'
```

This enables the hardened runtime, waits for Apple to accept the submission, staples the notarization ticket and verifies the extracted app with Gatekeeper. The distribution ZIP has a separate `-notarized` filename.
