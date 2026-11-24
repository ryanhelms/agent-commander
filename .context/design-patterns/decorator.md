---
type: Design Pattern
title: Decorator
description: "A decorator wraps an object with the same interface to layer behavior around individual calls."
family: GoF
category: Structural
tags:
  - composition
  - instrumentation
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: gof
    resource: https://www.informit.com/store/design-patterns-elements-of-reusable-object-oriented-9780201633610
    title: "Design Patterns: Elements of Reusable Object-Oriented Software"
    author: "human:gamma-helm-johnson-vlissides"
---

# Decorator

## When to use

Use decorators when independent behaviors such as timing and traffic accounting should be combined in different orders for different endpoints. If every caller needs exactly one fixed behavior, putting it directly in the implementation may be clearer.

## Abstract implementation

Each decorator implements the component's interface and holds another component. It can act before delegation, after the call returns, or when the call fails. The caller still sees the same operation and result contract.

For example, `CountingWriter(CompressingWriter(file)).write(data)` counts input bytes, while reversing the wrappers counts compressed bytes written to the file.

## Concrete implementation

An envisioned relay sender could measure logical submissions and individual network attempts separately. Put request timing outside retry handling and attempt timing inside it. Only retry operations with delivery semantics that make replay safe.

```text
wire = TransportSender(connection)
attempts = TimedSender("wire-attempt", wire)
retrying = RetrySender(attempts, retryableIdempotentDelivery)
sender = TimedSender("logical-send", retrying)
receipt = sender.send(message)
```

## Trade-offs

Ordering changes what gets measured or retried. A timing wrapper that drops the original error can invalidate the next layer's retry decision. Exercise cancellation and partial delivery with the final wrapper order.

## Commonly Used With

- [Proxy](proxy.md) can sit at the transport boundary underneath instrumentation decorators.
- [Strategy](strategy.md) can supply the retry decision used by one decorator.
