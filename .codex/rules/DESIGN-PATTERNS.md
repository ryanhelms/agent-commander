# Design pattern rules

Check applicable design patterns before every code change, including new features, bug fixes, refactors, and changes to tests or build code. Apply this across the native cockpit, CLI, services, providers, integrations, and multiplayer. Give delegated implementers the same check before they start.

1. Identify the behavior or invariant the change affects. Read the relevant part of the [project decision record](../../design/PATTERN-DECISIONS.md) and inspect the existing implementation and tests.
2. Check the relevant [catalog entries](../../.context/design-patterns/index.md). Use the Gang of Four catalog for recurring responsibilities and collaboration between components. Use Enterprise Integration Patterns for message exchanges with routing, delivery, ordering, or recovery requirements. Read the applicable “Commonly Used With” links when patterns interact. For relay work, start with the catalog’s relay questions and the applicable [relay architecture](../../design/MULTIPLAYER-RELAY.md).
3. Reuse the existing decision when it fits. Compare any proposed change with a direct function, query, or state transition. Choose the simplest approach that preserves the required behavior and failure guarantees.
4. When a design decision changes, put a short note in the issue or PR describing the choice and the behavior or failure it addresses. Update the project decision record in the same change. Record the affected flow and owner, the pattern or direct approach, its implementation status, and source and test evidence. Keep proposed or deferred work explicitly labeled. An unchanged design needs only the pre-change check.

The project decision record tracks Commander’s implementations. The catalog below lists available choices and links to their applicability, examples, and trade-offs.

## Gang of Four

### Creational

[Abstract Factory](../../.context/design-patterns/abstract-factory.md), [Builder](../../.context/design-patterns/builder.md), [Factory Method](../../.context/design-patterns/factory-method.md), [Prototype](../../.context/design-patterns/prototype.md), [Singleton](../../.context/design-patterns/singleton.md)

### Structural

[Adapter](../../.context/design-patterns/adapter.md), [Bridge](../../.context/design-patterns/bridge.md), [Composite](../../.context/design-patterns/composite.md), [Decorator](../../.context/design-patterns/decorator.md), [Facade](../../.context/design-patterns/facade.md), [Flyweight](../../.context/design-patterns/flyweight.md), [Proxy](../../.context/design-patterns/proxy.md)

### Behavioral

[Chain of Responsibility](../../.context/design-patterns/chain-of-responsibility.md), [Command](../../.context/design-patterns/command.md), [Interpreter](../../.context/design-patterns/interpreter.md), [Iterator](../../.context/design-patterns/iterator.md), [Mediator](../../.context/design-patterns/mediator.md), [Memento](../../.context/design-patterns/memento.md), [Observer](../../.context/design-patterns/observer.md), [State](../../.context/design-patterns/state.md), [Strategy](../../.context/design-patterns/strategy.md), [Template Method](../../.context/design-patterns/template-method.md), [Visitor](../../.context/design-patterns/visitor.md)

## Enterprise Integration Patterns

### Integration Styles

[File Transfer](../../.context/design-patterns/file-transfer.md), [Messaging](../../.context/design-patterns/messaging.md), [Remote Procedure Invocation](../../.context/design-patterns/remote-procedure-invocation.md), [Shared Database](../../.context/design-patterns/shared-database.md)

### Messaging Systems

[Message](../../.context/design-patterns/message.md), [Message Channel](../../.context/design-patterns/message-channel.md), [Message Endpoint](../../.context/design-patterns/message-endpoint.md), [Message Router](../../.context/design-patterns/message-router.md), [Message Translator](../../.context/design-patterns/message-translator.md), [Pipes and Filters](../../.context/design-patterns/pipes-and-filters.md)

### Messaging Channels

[Channel Adapter](../../.context/design-patterns/channel-adapter.md), [Datatype Channel](../../.context/design-patterns/datatype-channel.md), [Dead Letter Channel](../../.context/design-patterns/dead-letter-channel.md), [Guaranteed Delivery](../../.context/design-patterns/guaranteed-delivery.md), [Invalid Message Channel](../../.context/design-patterns/invalid-message-channel.md), [Message Bus](../../.context/design-patterns/message-bus.md), [Messaging Bridge](../../.context/design-patterns/messaging-bridge.md), [Point-to-Point Channel](../../.context/design-patterns/point-to-point-channel.md), [Publish-Subscribe Channel](../../.context/design-patterns/publish-subscribe-channel.md)

### Message Construction

[Command Message](../../.context/design-patterns/command-message.md), [Correlation Identifier](../../.context/design-patterns/correlation-identifier.md), [Document Message](../../.context/design-patterns/document-message.md), [Event Message](../../.context/design-patterns/event-message.md), [Format Indicator](../../.context/design-patterns/format-indicator.md), [Message Expiration](../../.context/design-patterns/message-expiration.md), [Message Sequence](../../.context/design-patterns/message-sequence.md), [Request-Reply](../../.context/design-patterns/request-reply.md), [Return Address](../../.context/design-patterns/return-address.md)

### Message Routing

[Aggregator](../../.context/design-patterns/aggregator.md), [Composed Message Processor](../../.context/design-patterns/composed-message-processor.md), [Content-Based Router](../../.context/design-patterns/content-based-router.md), [Dynamic Router](../../.context/design-patterns/dynamic-router.md), [Message Broker](../../.context/design-patterns/message-broker.md), [Message Filter](../../.context/design-patterns/message-filter.md), [Process Manager](../../.context/design-patterns/process-manager.md), [Recipient List](../../.context/design-patterns/recipient-list.md), [Resequencer](../../.context/design-patterns/resequencer.md), [Routing Slip](../../.context/design-patterns/routing-slip.md), [Scatter-Gather](../../.context/design-patterns/scatter-gather.md), [Splitter](../../.context/design-patterns/splitter.md)

### Message Transformation

[Canonical Data Model](../../.context/design-patterns/canonical-data-model.md), [Claim Check](../../.context/design-patterns/claim-check.md), [Content Enricher](../../.context/design-patterns/content-enricher.md), [Content Filter](../../.context/design-patterns/content-filter.md), [Envelope Wrapper](../../.context/design-patterns/envelope-wrapper.md), [Normalizer](../../.context/design-patterns/normalizer.md)

### Messaging Endpoints

[Competing Consumers](../../.context/design-patterns/competing-consumers.md), [Durable Subscriber](../../.context/design-patterns/durable-subscriber.md), [Event-Driven Consumer](../../.context/design-patterns/event-driven-consumer.md), [Idempotent Receiver](../../.context/design-patterns/idempotent-receiver.md), [Message Dispatcher](../../.context/design-patterns/message-dispatcher.md), [Messaging Gateway](../../.context/design-patterns/messaging-gateway.md), [Messaging Mapper](../../.context/design-patterns/messaging-mapper.md), [Polling Consumer](../../.context/design-patterns/polling-consumer.md), [Selective Consumer](../../.context/design-patterns/selective-consumer.md), [Service Activator](../../.context/design-patterns/service-activator.md), [Transactional Client](../../.context/design-patterns/transactional-client.md)

### System Management

[Channel Purger](../../.context/design-patterns/channel-purger.md), [Control Bus](../../.context/design-patterns/control-bus.md), [Detour](../../.context/design-patterns/detour.md), [Message History](../../.context/design-patterns/message-history.md), [Message Store](../../.context/design-patterns/message-store.md), [Smart Proxy](../../.context/design-patterns/smart-proxy.md), [Test Message](../../.context/design-patterns/test-message.md), [Wire Tap](../../.context/design-patterns/wire-tap.md)

[Gang of Four publisher](https://www.informit.com/store/design-patterns-elements-of-reusable-object-oriented-9780201633610) · [Enterprise Integration Patterns catalog](https://www.enterpriseintegrationpatterns.com/patterns/messaging/toc.html)
