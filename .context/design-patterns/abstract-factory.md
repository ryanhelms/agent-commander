---
type: Design Pattern
title: Abstract Factory
description: "An abstract factory constructs related products whose implementations must agree on a shared environment."
family: GoF
category: Creational
tags:
  - construction
  - compatibility
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: gof
    resource: https://www.informit.com/store/design-patterns-elements-of-reusable-object-oriented-9780201633610
    title: "Design Patterns: Elements of Reusable Object-Oriented Software"
    author: "human:gamma-helm-johnson-vlissides"
---

# Abstract Factory

## When to use

Choose this when selecting a backend also determines several cooperating components. A connection opener and its history reader, for example, may need to agree on a session identifier format. With a single interchangeable component, a constructor argument usually suffices.

## Abstract implementation

Declare a factory interface with one creation operation per product role. Each concrete factory constructs a compatible family. The client receives the factory once, asks it for the products it needs, and refers to those products through their own interfaces.

For example, `paint(theme.makePanel(), theme.makeButton())` draws two products selected by the same theme factory.

## Concrete implementation

An envisioned Go relay could choose a local or SSH session factory during host enrollment. A factory bound to one host would supply both a transport and a history reader. A lookup failure would surface as an enrollment error before the worker starts.

```text
factory = factories.require(host.kind).bind(host)
transport = factory.openTransport()
history = factory.newHistoryReader()
session = transport.open(assignment)
history.readSince(session.id, cursor)
```

## Trade-offs

Adding a host family keeps the consumer stable. Adding a new product role affects every factory. Contract tests should create a session using each family and read it back using the paired reader.

## Commonly Used With

- [Factory Method](factory-method.md) can supply an individual product inside a concrete family.
- [Bridge](bridge.md) can consume the selected implementation family while keeping the public session operations independent.
