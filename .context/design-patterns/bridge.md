---
type: Design Pattern
title: Bridge
description: "A bridge separates a service abstraction from its implementation so each can vary along its own dimension."
family: GoF
category: Structural
tags:
  - interfaces
  - composition
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: gof
    resource: https://www.informit.com/store/design-patterns-elements-of-reusable-object-oriented-9780201633610
    title: "Design Patterns: Elements of Reusable Object-Oriented Software"
    author: "human:gamma-helm-johnson-vlissides"
---

# Bridge

## When to use

Choose a bridge when two dimensions change independently. For instance, a read-only session and an interactive session could each work over either a local helper or an enrolled remote helper.

## Abstract implementation

The abstraction stores an implementation interface and builds higher-level operations on its primitives. A refined abstraction adds its own behavior while using the same implementation contract. Adding a new implementation then serves every compatible refinement.

For example, `WarningAlert(renderer).display()` can use either a speech renderer or a screen renderer. Both renderers also work with an ordinary information alert.

## Concrete implementation

A proposed relay console could implement two client-facing session types. A read-only type would expose snapshots. An interactive type would also send input through a host transport after authority checks. Both could use a local transport or a relayed transport.

```text
observed = ReadOnlySession(workerID, remoteTransport)
controlled = ControlledSession(workerID, remoteTransport, inputLease)
observed.snapshot(cursor)
controlled.sendInput(text, inputLease.generation)
```

## Trade-offs

This avoids a separate class for every session/transport pair. A lowest-common-denominator transport can obscure capability gaps. Expose capabilities explicitly, and have the executing host validate the input lease for every write.

## Commonly Used With

- [Adapter](adapter.md) can make an existing provider conform to the implementation side of the bridge.
- [Abstract Factory](abstract-factory.md) can choose a compatible host transport when constructing a session abstraction.
