# Pattern catalog review for the harness integration interview

This is a design review for Agent Commander. Each row connects a published pattern to a specific decision or failure mode. “Existing” means the repository already describes the design intent. “Candidate” means a proposal to evaluate. “Conditional” gives a trigger for revisiting a pattern. “Defer” means the current requirements supply little reason to implement it. Implementation readiness and protocol conformance require separate verification.

The current project plan selects Agent Client Protocol v1 for the provider connection, with native ACP first and upstream Claude/Codex adapters to evaluate. The Commander API owns commands, permissions, ownership and receipts. AG-UI carries conversation projections. The native app already has a live feed, and CopilotKit has a separate proof. Harnesses own transcript contents and retention. Commander keeps bounded live projections, session references and its own operation data. User decisions can revise these boundaries. [MVP plan](../MVP-PLAN.md) · [History policy](../MVP-PLAN.md) · [Repository pattern decisions](PATTERN-DECISIONS.md)

## Original Gang of Four catalog

The publisher lists five creational, seven structural and eleven behavioral patterns. A constructor registry and Go interfaces can be straightforward implementation choices. Factory Method and Abstract Factory introduce specific creation responsibilities beyond looking up a constructor by name. [Publisher's detailed table of contents](https://www.informit.com/store/design-patterns-elements-of-reusable-object-oriented-9780321770462)

| Family | Pattern | Status and relevance |
| --- | --- | --- |
| Creational | Abstract Factory | Conditional. A provider may need a compatible family of session opener, live controller and independent history reader. A single adapter constructor suffices while only one product is needed. |
| Creational | Builder | Conditional. Consider a validated builder if configuring remote transport, credentials, capabilities and versions produces many invalid setup combinations. |
| Creational | Factory Method | Conditional. An extensible host workflow could delegate creation of a session driver to each implementation. First test whether a simple registered constructor covers it. |
| Creational | Prototype | Defer. Forking a conversation requires provider-supported lineage, session identity and evidence about pending work. Copying a driver object cannot supply those. |
| Creational | Singleton | Defer. Service-owned registries can be passed explicitly. Isolated hosts and parallel fixture tests benefit from independent instances. |
| Structural | Adapter | Existing. Implement a stable session interface over the harness's native ACP endpoint, upstream adapter or a documented native interface. Record support per operation. |
| Structural | Bridge | Conditional. If each harness must work across independently changing local and remote transports, separate the session abstraction from the host transport implementation. |
| Structural | Composite | Conditional. Use a common operation on individual sessions and worker groups only when semantics such as stopping a subtree are defined across both. |
| Structural | Decorator | Conditional. Apply the same tracing or quota behavior to multiple drivers when the behavior and failure contract are identical. |
| Structural | Facade | Existing. The Commander API gives native, CLI, MCP and prospective CopilotKit ingress the same domain commands and validation. |
| Structural | Flyweight | Defer. Consider interning immutable, repeated schema descriptors only after profiling proves a memory issue. Session and authorization state remain individually scoped. |
| Structural | Proxy | Conditional. A remote driver reference may need a local object that forwards calls, checks liveness and exposes connection failures explicitly. |
| Behavioral | Chain of Responsibility | Conditional. Use a short documented sequence of history resolvers if native ACP and provider-specific APIs offer complementary history, with explicit rules for unsupported, denied and failed reads. |
| Behavioral | Command | Existing. Represent mutations such as sending a turn, approving a request and stopping a worker with targets, preconditions and operation identity. |
| Behavioral | Interpreter | Defer. Capability manifests can use structured fields. Revisit if the user needs a genuine expression language for selecting or routing harnesses. |
| Behavioral | Iterator | Candidate. Offer cursor-based iteration over paged provider history with explicit end, source unavailability and gaps. |
| Behavioral | Mediator | Conditional. Evaluate when many independently evolving conversation components must coordinate through one interaction policy. The service already owns the relevant domain commands. |
| Behavioral | Memento | Conditional. A provider may return an opaque restore token. Document its lifetime and authority before offering resume from that token. |
| Behavioral | Observer | Existing at the UI level. Let multiple native views observe the same worker presentation state without each launching a harness connection. |
| Behavioral | State | Conditional. Introduce separate behavioral states when connecting, authenticating, active, awaiting approval and reconnecting develop substantially different transition behavior. |
| Behavioral | Strategy | Existing for identity resolution. Candidate for interchangeable history or delivery algorithms when two supported implementations make materially different choices. |
| Behavioral | Template Method | Conditional. A framework can own negotiation, validation and session teardown while drivers supply selected steps. Prefer explicit hooks or functions in Go when inheritance adds no value. |
| Behavioral | Visitor | Defer for an open provider event vocabulary. A visitor over a closed standardized projection could be useful, provided extensions and unknown records retain a generic inspector. |

## Enterprise Integration Patterns messaging catalog

The authors' 65-entry catalog includes integration styles, messaging systems, channels, message construction, routing, transformation, endpoints and system management. Here the names match their detailed table of contents. The mapping describes proposed software behavior and does not require a broker or integration product. [Messaging catalog](https://www.enterpriseintegrationpatterns.com/patterns/messaging/toc.html)

| Family | Pattern | Status and relevance |
| --- | --- | --- |
| Integration styles | File Transfer | Conditional. Accept a verified provider-owned journal or explicit import as an offline exchange when the live API cannot supply that material. |
| Integration styles | Shared Database | Defer. A provider's private database schema ties Commander to vendor migrations and retention behavior. Prefer supported history interfaces. |
| Integration styles | Remote Procedure Invocation | Existing. Commander commands and ACP request methods already entail request outcomes and communication failures. |
| Integration styles | Messaging | Existing. Streaming provider notifications and user-interface events decouple the producer from readers. |
| Messaging systems | Message Channel | Existing. Separate conversation updates, commands and terminal bytes by their delivery and authorization needs. |
| Messaging systems | Message | Candidate. Specify typed payload, identity, origin and version for normalized provider events, including a defined representation for extensions. |
| Messaging systems | Pipes and Filters | Conditional. Separate decode, translation and presentation when each stage can be tested and composed independently. |
| Messaging systems | Message Router | Candidate. Route a command by verified worker and session binding to the registered driver, with a typed error when unsupported. |
| Messaging systems | Message Translator | Existing. Convert ACP or native provider data into a projection suitable for AG-UI, preserving source identity and fields that have no standard equivalent. |
| Messaging systems | Message Endpoint | Existing. A service-owned provider session reads notifications and sends requests. UI connections use their separately scoped endpoint. |
| Messaging channels | Point-to-Point Channel | Existing as a logical addressing rule. A worker reply reaches its identified pending request and controlling host. |
| Messaging channels | Publish-Subscribe Channel | Existing. Wall, focused console and other observers can receive state changes for the same conversation. |
| Messaging channels | Datatype Channel | Conditional. Introduce separate lanes when heavy terminal output delays a small approval, lifecycle event or user command. |
| Messaging channels | Invalid Message Channel | Conditional. Emit bounded parse diagnostics for malformed source frames and preserve evidence according to policy. A well-formed unfamiliar extension remains a valid event. |
| Messaging channels | Dead Letter Channel | Conditional. If durable outbound delivery exists, isolate operations that exhaust delivery attempts and retain their reconciliation status. |
| Messaging channels | Guaranteed Delivery | Conditional. Guarantee persistence and retry only across boundaries with durable acceptance evidence. Show uncertain provider execution when its receipt is lost. |
| Messaging channels | Channel Adapter | Candidate. Connect a supported native CLI stream to the shared message path. A generic terminal profile can advertise only the observations and controls it actually provides. |
| Messaging channels | Messaging Bridge | Conditional. An independently running ACP gateway and a second messaging system may need translation of addressing and delivery semantics. |
| Messaging channels | Message Bus | Defer. A local versioned API and kernel-managed streams can serve the current single-user scope. Revisit with independently deployed systems and shared routing needs. |
| Message construction | Command Message | Existing. Deliver a named command, reason, target and preconditions to the authority capable of carrying it out. |
| Message construction | Document Message | Conditional. A history page or manifest can carry a self-contained snapshot through an import or synchronization interface. |
| Message construction | Event Message | Existing. Represent observations such as a tool call finishing or a request opening as facts without giving them command authority. |
| Message construction | Request-Reply | Existing. Attach approval and question answers to their initiating request and return the recorded outcome. |
| Message construction | Return Address | Conditional. If an asynchronous plugin can reply over more than one channel, preserve the authorized callback route or session binding. |
| Message construction | Correlation Identifier | Existing. Scope IDs to worker, native session, turn, request and tool call as appropriate. Two drivers can reuse the same provider-local ID. |
| Message construction | Message Sequence | Conditional. Chunk large provider payloads only when the transport needs it. Carry identity, sequence position and a way to detect missing parts. |
| Message construction | Message Expiration | Conditional. Expire live approval prompts on provider cancellation or expiry. Retain Commander-owned resolution records under the operation policy. |
| Message construction | Format Indicator | Candidate. Declare negotiated protocol and projection versions and extension namespaces. Distinguish current live events from legacy saved formats. |
| Message routing | Content-Based Router | Conditional. Use declared event kind or capability to route observations to a translator. Control commands still address the verified worker. |
| Message routing | Message Filter | Candidate. Suppress repeated progress noise in a view while preserving access to its available events or source references. |
| Message routing | Dynamic Router | Conditional. A live directory may update routing as independently installed plugins advertise or lose capabilities. |
| Message routing | Recipient List | Conditional. Fan out an explicitly authorized broadcast command to a recorded set of target workers and report each outcome separately. |
| Message routing | Splitter | Candidate. Divide multi-block messages into ordered renderable parts that still refer to the complete source message. |
| Message routing | Aggregator | Candidate. Combine partial and final updates for one provider item while preserving the distinct events, errors and authoritative final value. |
| Message routing | Resequencer | Conditional. Reorder only when the source provides a reliable sequence for that stream. Otherwise record observed order and disclose gaps. |
| Message routing | Composed Message Processor | Conditional. Consider if split multi-part records need independent processing, routing and subsequent reassembly into a coherent item. |
| Message routing | Scatter-Gather | Conditional. A user-requested capability survey across multiple remote hosts could run in parallel and gather results with an explicit deadline. |
| Message routing | Routing Slip | Defer. Revisit for configurable ordered processing stages selected at runtime, such as an administrator-defined export pipeline. |
| Message routing | Process Manager | Conditional in the project. Multi-host recovery or worker adoption may need persisted state across branching asynchronous participants. |
| Message routing | Message Broker | Defer. Revisit when independent deployments require central routing, buffering or operational isolation beyond the host service. |
| Message transformation | Envelope Wrapper | Candidate. Associate normalized content with worker, provider version, native identifiers and source position. Preserve native-only fields within the authorization and retention policy. |
| Message transformation | Content Enricher | Candidate. Supply verified worker and run attribution from Commander. Label timestamps measured locally separately from provider timestamps. |
| Message transformation | Content Filter | Candidate. AG-UI state can carry bounded summaries and typed disclosure references for larger source details. |
| Message transformation | Claim Check | Conditional. An authorized, expiring reference can resolve a provider-backed attachment on demand. If the source expires, show its recorded identity and availability. |
| Message transformation | Normalizer | Candidate. Map equivalent tool starts, deltas, completions and results across ACP/native formats with provider-specific translation. |
| Message transformation | Canonical Data Model | Candidate. Define shared semantics for sessions, turns, blocks, capabilities and command outcomes while retaining provider extensions. Give each boundary an explicit compatibility policy. |
| Messaging endpoints | Messaging Gateway | Conditional in the project. Hide true messaging mechanics behind the domain-facing interface for an addressed inbox or out-of-process driver. |
| Messaging endpoints | Messaging Mapper | Candidate. Keep protocol wire objects and domain/session records independently versioned through typed conversion and contract tests. |
| Messaging endpoints | Transactional Client | Conditional. Use transactional handling if a durable broker is introduced and the acknowledgment must follow a local state commit. |
| Messaging endpoints | Polling Consumer | Existing as an option. Poll a worker inbox or supported history API where push delivery is unavailable. Expose limits and cursor behavior. |
| Messaging endpoints | Event-Driven Consumer | Existing. Consume live provider updates as they arrive without having each UI poll the CLI. |
| Messaging endpoints | Competing Consumers | Defer. A single session's ordered mutations require one execution authority. Consider parallel consumers only for safely partitionable work. |
| Messaging endpoints | Message Dispatcher | Conditional. One shared transport may need a dispatcher to find its session-scoped consumer if the protocol multiplexes sessions. |
| Messaging endpoints | Selective Consumer | Conditional. Route subscriptions by project and session to keep each reader within its scope. Enforce authorization at the source. |
| Messaging endpoints | Durable Subscriber | Conditional. A reader can resume from a durable cursor only where the source can replay the required records after disconnect. |
| Messaging endpoints | Idempotent Receiver | Existing. Deduplicate retried mutations by scoped operation identity and intent, and reconcile uncertain side effects before repeating them. |
| Messaging endpoints | Service Activator | Conditional. Externally supplied broker commands may call the same authorization-checked domain service as the local API. |
| System management | Control Bus | Defer. Consider a separate administrative channel for independently managed remote host fleets. |
| System management | Detour | Conditional. A diagnostic session could route isolated fixture traffic through a candidate adapter for compatibility testing. |
| System management | Wire Tap | Conditional. Explicitly scoped, temporary recording can aid protocol comparison when the recording policy allows it. |
| System management | Message History | Candidate. Include per-hop operation and source identifiers sufficient to trace a user command and its delivery evidence. |
| System management | Message Store | Existing. Persist Commander-owned receipts, pending actions and operation outcomes. Existing policy assigns transcript storage to the harness. |
| System management | Smart Proxy | Conditional. A remote bridge may need to rewrite return addresses and correlate replies to a short-lived client connection. |
| System management | Test Message | Candidate. An isolated conformance fixture can traverse production-shaped interfaces to check live event, replay and permission semantics. |
| System management | Channel Purger | Defer. Give conformance tests disposable channels and state directories. Diagnose stale operation claims through scoped reconciliation. |

## Conversation patterns on the authors' site

The authors separately label this catalog a work in progress. Its published navigation exposes 32 topic entries across describing conversations (4), discovery (5), starting a conversation (5), basic conversations (6), intermediaries (4), distributed-system management (1), resource management (3) and ensuring consistency (4). These entries include introductory modeling concepts. The 32 are separate from the 65 messaging patterns. [Conversation catalog and status](https://www.enterpriseintegrationpatterns.com/patterns/conversation/)

| Family | Published topics | Consequence to discuss |
| --- | --- | --- |
| Description | Choreography, Orchestration, Hypermedia State, Conversation Vocabulary | Specify which participant may initiate a transition, how capability state changes and how a client learns what action remains available. |
| Discovery | Dynamic Discovery, Advertise Availability, Consult Directory, Referral, Leader Election | A local manifest registry may suffice. Runtime plugin discovery, remote referral and multiple controllers with leader election each introduce different lifecycle requirements. |
| Starting a conversation | Three-Way Hand Shake, Acquire Token First, Rotate Tokens, Verify Identity, User Grants Access | A startup negotiation must establish compatible versions, verified agent identity, optional capabilities and the permissions of that connection. |
| Basic conversations | Fire-and-Forget, Asynchronous Request-Response, Request-Response with Retry, Polling, Subscribe-Notify, Quick Acknowledgment | Separate service acceptance, provider delivery and completion. Choose retry semantics per operation, and use notifications for observations. |
| Intermediaries | Proxy, Relay, Load Balancer, Scatter-Gather | Scope mediation to the selected host and worker. Fleet balancing and cross-host scanning depend on deployment choices. |
| Distributed systems | Heartbeat | A liveness signal and an operation acknowledgment answer different questions. Show both when diagnosing a disconnect. |
| Resource management | Incremental State Build-up, Lease, Renewal Reminder | Scope stream or adapter leases explicitly. Existing Commander input ownership lasts until explicit handback, so changing it to a timer is a product decision. |
| Consistency | Ignore Error, Compensating Action, Tentative Operation, Coordinated Agreement | Acknowledge only evidence-supported outcomes. Define compensations for reversible steps before attempting distributed coordination. |

## Scenarios for the requirements interview

1. Which capabilities earn a harness a launchable, conversational or read-only place in Commander? Specify the user-visible behavior for an ordinary terminal-only CLI.
2. Release one must accept built-in Go adapters and independently installed executables. Specify who installs each executable, who trusts it, how it upgrades, and how it passes the common conformance suite.
3. How should full-fidelity availability work when a provider's live stream contains fields its replay API omits? Keep the source-ownership decision visible when discussing offline access.
4. Which surfaces can initiate each action, and which approval/reply must survive a crash? Determine the required delivery evidence separately for prompts, approvals, cancellation and control handback.
5. What constitutes passing conformance? Include a third harness, a vendor extension, a missing optional capability, a duplicate delivery, a restart and a permission request across both native and CopilotKit surfaces.

**Coverage counts** span 23 GoF entries (5 + 7 + 11), 65 messaging entries (4 + 6 + 9 + 9 + 12 + 6 + 11 + 8), and the separate conversation catalog's 32 listed topics. Scope is the catalog entries, their architectural applicability and the project’s existing constraints.
