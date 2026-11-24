---
okf_version: "0.2"
---

# Design pattern index

Use this index to choose a pattern by the problem it solves. Each entry links to one OKF concept with decision cues, abstract and concrete implementation examples, trade-offs, and links to commonly paired patterns. The relay examples illustrate design options. The [multiplayer relay architecture](../../design/MULTIPLAYER-RELAY.md) and [project decisions](../../design/PATTERN-DECISIONS.md) record which options the project adopts.

## Start with a relay problem

| Design question | Read in this order |
| --- | --- |
| How does one request reach every selected agent? | [Recipient List](recipient-list.md) expands the audience. [Competing Consumers](competing-consumers.md) spreads the resulting work across dispatchers. [Aggregator](aggregator.md) assembles partial outcomes. |
| How does a new edge find a device after reconnect? | [Dynamic Router](dynamic-router.md) resolves the current owner. [Fencing Token](fencing-token.md) protects the newer session. |
| How do retries preserve a paid operation? | [Correlation Identifier](correlation-identifier.md) ties attempts together. [Transactional Outbox](transactional-outbox.md) persists the dispatch intent. [Idempotent Receiver](idempotent-receiver.md) returns the existing receipt. |
| Where should a new transport or selection rule plug in? | [Adapter](adapter.md) maps a transport. [Strategy](strategy.md) supplies a selection algorithm. [Messaging Gateway](messaging-gateway.md) exposes the domain operation. |
| How can offline peers and slow observers catch up? | [Durable Subscriber](durable-subscriber.md) retains progress. [Message Expiration](message-expiration.md) bounds outstanding work. [Message Store](message-store.md) records recoverable outcomes. |

## Catalog scope

The bundle covers the 23 Gang of Four patterns and all 65 patterns in Hohpe and Woolf’s messaging table of contents. Two separately attributed distributed-systems entries cover persistence and ownership in the proposed relay. [GoF publisher](https://www.informit.com/store/design-patterns-elements-of-reusable-object-oriented-9780201633610) · [EIP catalog](https://www.enterpriseintegrationpatterns.com/patterns/messaging/toc.html) · [Open Knowledge Format 0.2](https://github.com/GoogleCloudPlatform/knowledge-catalog/blob/main/okf/SPEC.md)

Each concept’s file stem is its stable OKF identifier. Query `family`, `category` and `tags` to narrow retrieval. `sources` identifies the original reference. `status` describes the reference page’s lifecycle. When extending the library, add one concept per file, include both implementation examples and link the entry under its category.

## Gang of Four

### Creational

- [Abstract Factory](abstract-factory.md) — An abstract factory constructs related products whose implementations must agree on a shared environment.
- [Builder](builder.md) — A builder assembles a complex product in stages and exposes it once its required parts agree.
- [Factory Method](factory-method.md) — A factory method lets a specialized creator choose a product while the shared workflow uses its common interface.
- [Prototype](prototype.md) — A prototype produces a new object by copying an existing example and defining which state the copy owns.
- [Singleton](singleton.md) — A singleton controls construction so callers inside a defined runtime share one instance.

### Structural

- [Adapter](adapter.md) — An adapter maps an existing component's operations and data to the interface its caller expects.
- [Bridge](bridge.md) — A bridge separates a service abstraction from its implementation so each can vary along its own dimension.
- [Composite](composite.md) — A composite lets clients operate on individual leaves and nested groups through the same interface.
- [Decorator](decorator.md) — A decorator wraps an object with the same interface to layer behavior around individual calls.
- [Facade](facade.md) — A facade gives clients a small entry point for an operation that spans several subsystem interfaces.
- [Flyweight](flyweight.md) — A flyweight shares immutable intrinsic data among many instances while callers supply their changing context.
- [Proxy](proxy.md) — A proxy represents another object and controls how clients reach it through the same interface.

### Behavioral

- [Chain of Responsibility](chain-of-responsibility.md) — A chain of responsibility gives a sequence of handlers an opportunity to handle a request or pass it onward.
- [Command](command.md) — A command represents an intended action as data so acceptance and execution can happen at different times.
- [Interpreter](interpreter.md) — An interpreter represents a small language as expressions whose meaning is evaluated against a context.
- [Iterator](iterator.md) — An iterator exposes a traversal while keeping collection storage and cursor mechanics inside the collection boundary.
- [Mediator](mediator.md) — A mediator coordinates a set of participants that would otherwise need detailed knowledge of each other.
- [Memento](memento.md) — A memento captures an object's state in an opaque snapshot that the originating object can later restore.
- [Observer](observer.md) — An observer subscribes to changes from a subject and can detach without changing the subject's behavior.
- [State](state.md) — The state pattern delegates an object's event handling to the object representing its current lifecycle phase.
- [Strategy](strategy.md) — A strategy makes a replaceable algorithm an explicit dependency of the operation that uses it.
- [Template Method](template-method.md) — A template method fixes the sequence of an operation while granting implementations control over selected steps.
- [Visitor](visitor.md) — A visitor adds type-specific operations over a stable family of elements while keeping those operations together.

## Enterprise Integration Patterns

### Integration Styles

- [File Transfer](file-transfer.md) — Applications exchange data by publishing complete files that another application imports on its own schedule.
- [Messaging](messaging.md) — Applications exchange discrete messages through a transport so sending and processing can happen separately.
- [Remote Procedure Invocation](remote-procedure-invocation.md) — A caller integrates with another application through a named operation and its request and response contract.
- [Shared Database](shared-database.md) — Several applications integrate by reading and updating a common data model in one database.

### Messaging Systems

- [Message](message.md) — A transport carries one bounded unit containing a payload and the metadata needed to deliver and interpret it.
- [Message Channel](message-channel.md) — A named communication path connects senders to receivers under a shared delivery contract.
- [Message Endpoint](message-endpoint.md) — An application uses a transport-facing component to send messages to a channel or receive them from one.
- [Message Router](message-router.md) — An intermediary selects the next channel for a message using routing information and a routing rule.
- [Message Translator](message-translator.md) — A boundary component converts a message between representations while preserving its business meaning.
- [Pipes and Filters](pipes-and-filters.md) — A pipeline decomposes processing into stages connected by channels with explicit input and output contracts.

### Messaging Channels

- [Channel Adapter](channel-adapter.md) — An adapter connects an application's existing interface to a messaging channel.
- [Datatype Channel](datatype-channel.md) — Each channel carries one agreed data type so the channel identifies the expected message representation.
- [Dead Letter Channel](dead-letter-channel.md) — The messaging system diverts messages it can no longer deliver under its routing and retry policies.
- [Guaranteed Delivery](guaranteed-delivery.md) — Durable custody at each handoff allows accepted messages to survive component failure and resume delivery.
- [Invalid Message Channel](invalid-message-channel.md) — A receiver moves messages that fail its acceptance rules to a dedicated inspection channel.
- [Message Bus](message-bus.md) — Applications integrate through shared messaging infrastructure, common contracts and agreed operation names.
- [Messaging Bridge](messaging-bridge.md) — A bridge transfers messages between two messaging systems that cannot communicate directly.
- [Point-to-Point Channel](point-to-point-channel.md) — A queue delivers each message to one logical consumer among the workers attached to it.
- [Publish-Subscribe Channel](publish-subscribe-channel.md) — A published message reaches each eligible subscription independently.

### Message Construction

- [Command Message](command-message.md) — A message asks its recipient to perform a named operation with supplied arguments.
- [Correlation Identifier](correlation-identifier.md) — A reply carries a value that identifies the request to which it belongs.
- [Document Message](document-message.md) — A sender transfers a self-contained representation of data for the receiver to use.
- [Event Message](event-message.md) — A publisher announces that a specific occurrence has already taken place.
- [Format Indicator](format-indicator.md) — A message declares the format needed to interpret its content.
- [Message Expiration](message-expiration.md) — A message carries a validity limit after which the system stops delivering or acting on it.
- [Message Sequence](message-sequence.md) — A sender represents a large logical message as identified parts that a receiver can reassemble.
- [Request-Reply](request-reply.md) — Two messages connect a request to a subsequently delivered answer.
- [Return Address](return-address.md) — A requester includes the destination to which its reply should be sent.

### Message Routing

- [Aggregator](aggregator.md) — An aggregator collects related messages until a completion rule permits one combined result.
- [Composed Message Processor](composed-message-processor.md) — A composed processor splits a composite input, routes its parts, and aggregates their outcomes.
- [Content-Based Router](content-based-router.md) — A router selects a destination by evaluating fields in each message.
- [Dynamic Router](dynamic-router.md) — A router updates routing rules as participants advertise or withdraw capabilities.
- [Message Broker](message-broker.md) — A message broker centralizes routing and delivery between participants that evolve independently.
- [Message Filter](message-filter.md) — A filter forwards messages that satisfy a predicate and discards the rest.
- [Process Manager](process-manager.md) — A process manager stores workflow state and selects the next action when events arrive.
- [Recipient List](recipient-list.md) — A dispatcher sends a separate copy of a message to each selected recipient.
- [Resequencer](resequencer.md) — A resequencer buffers related messages and emits them in the required order.
- [Routing Slip](routing-slip.md) — A routing slip carries an ordered list of processing steps for one message.
- [Scatter-Gather](scatter-gather.md) — A requester sends a query to multiple recipients and combines their replies under a completion policy.
- [Splitter](splitter.md) — A splitter turns independently processable elements of one input into separate messages.

### Message Transformation

- [Canonical Data Model](canonical-data-model.md) — A shared data model gives independent integrations one agreed representation of common domain concepts.
- [Claim Check](claim-check.md) — A claim check replaces a bulky payload with a reference that an authorized consumer can redeem.
- [Content Enricher](content-enricher.md) — An enricher adds missing information from an authoritative source before a message proceeds.
- [Content Filter](content-filter.md) — A content filter projects selected information into a smaller message for a particular consumer.
- [Envelope Wrapper](envelope-wrapper.md) — An envelope adds transport metadata around an intact application message.
- [Normalizer](normalizer.md) — A normalizer translates equivalent inputs from several formats into one representation for downstream consumers.

### Messaging Endpoints

- [Competing Consumers](competing-consumers.md) — Share one logical subscription across workers that can each handle any work item.
- [Durable Subscriber](durable-subscriber.md) — Keep a subscription’s delivery position across disconnects so retained messages can be resumed.
- [Event-Driven Consumer](event-driven-consumer.md) — Register a handler that the messaging endpoint invokes when a matching message arrives.
- [Idempotent Receiver](idempotent-receiver.md) — Recognize repeat attempts or design an operation whose repeated application has the same effect.
- [Message Dispatcher](message-dispatcher.md) — Consume from one channel and delegate each message to a selected local performer.
- [Messaging Gateway](messaging-gateway.md) — Hide broker operations behind a domain operation with explicit delivery semantics.
- [Messaging Mapper](messaging-mapper.md) — Convert between domain objects and wire records in an independently testable component.
- [Polling Consumer](polling-consumer.md) — Let a receiver request messages when it has capacity to process them.
- [Selective Consumer](selective-consumer.md) — Receive only the messages matching a subscription’s selection criteria.
- [Service Activator](service-activator.md) — Translate an incoming message into an invocation of an application service and publish its outcome.
- [Transactional Client](transactional-client.md) — Use the messaging system’s transaction boundary to commit or roll back related messaging operations together.

### System Management

- [Channel Purger](channel-purger.md) — A channel purger removes unwanted messages from a bounded channel under an explicit cleanup policy.
- [Control Bus](control-bus.md) — A control bus carries administrative commands and operational status between messaging components.
- [Detour](detour.md) — A detour temporarily inserts an additional processing path before messages return to their usual flow.
- [Message History](message-history.md) — Message history records the processing path of an individual message.
- [Message Store](message-store.md) — A message store retains selected message data for later querying independently of delivery.
- [Smart Proxy](smart-proxy.md) — A smart proxy tracks a request and its reply by substituting its own return address and forwarding the response.
- [Test Message](test-message.md) — A test message traverses a real processing path and produces a known outcome that an observer can verify.
- [Wire Tap](wire-tap.md) — A wire tap copies traffic to a second destination for observation while the original message continues.

## Distributed systems companions

### Data and Consistency

- [Fencing Token](fencing-token.md) — Attach a monotonically increasing ownership generation to a lease and reject superseded owners at the protected operation.
- [Transactional Outbox](transactional-outbox.md) — Record publication intent in the database transaction that changes domain state, then relay it to the broker.
