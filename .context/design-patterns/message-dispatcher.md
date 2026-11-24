---
type: Design Pattern
title: "Message Dispatcher"
description: "Consume from one channel and delegate each message to a selected local performer."
family: EIP
category: Messaging Endpoints
tags: ["dispatch","extension","handlers"]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: eip
    resource: https://www.enterpriseintegrationpatterns.com/patterns/messaging/MessageDispatcher.html
    title: "Message Dispatcher"
    author: "human:hohpe-woolf"
---

# Message Dispatcher

## When to use

Use when one service owns consumption and acknowledgements while several local handlers implement different operations.

## Abstract implementation

One accounting listener validates a message type, selects a registered performer and delegates an invoice, adjustment or cancellation. The common listener owns lifecycle and error reporting.

Example — `performer = handlers[(kind, version)]; outcome = performer.handle(validated_message)`

## Concrete implementation

In a Go relay dispatcher, a startup registry maps `(kind, majorVersion)` to trusted handlers. The dispatcher checks envelope size, authentication, expiry and operation scope before invoking the registered handler. It records the outcome under the delivery ID and acknowledges according to the handler contract.

## Trade-offs

An arbitrary handler name or unbounded goroutine per message turns a registry into an unsafe dispatch surface. Validate registered keys at startup, bound parallelism and define terminal behavior for unsupported versions.

## Commonly Used With

- [Strategy](strategy.md) encapsulates each interchangeable handling policy.
- [Invalid Message Channel](invalid-message-channel.md) separates malformed records from retryable delivery failures.
