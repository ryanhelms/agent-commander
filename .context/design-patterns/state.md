---
type: Design Pattern
title: State
description: "The state pattern delegates an object's event handling to the object representing its current lifecycle phase."
family: GoF
category: Behavioral
tags:
  - lifecycle
  - transitions
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: gof
    resource: https://www.informit.com/store/design-patterns-elements-of-reusable-object-oriented-9780201633610
    title: "Design Patterns: Elements of Reusable Object-Oriented Software"
    author: "human:gamma-helm-johnson-vlissides"
---

# State

## When to use

Choose this when the same event means different things in different phases and branching logic has spread across callers. A pending handoff and an accepted handoff, for instance, handle cancellation differently.

## Abstract implementation

A context stores the current state. Each state implements the same event-handling interface and selects the result and next state. Persist a stable state identifier when the lifecycle must survive restart. A transition table is often simpler for a small fixed workflow.

For example, `player.state.handle(Play)` can resume the saved position in the paused state and begin at the first frame in the stopped state.

## Concrete implementation

An envisioned relay could handle canceling a shared turn using phase-specific handlers. Canceling a queued turn can release a reservation. Canceling a running turn creates a stop request and holds the reservation until the host confirms what ran.

```text
handle(turn, Cancel):
    next, effects = states[turn.phase].handle(Cancel)
    transaction:
        saveIfVersion(turn.id, turn.version, next)
        enqueueOnce(turn.id, next.version, effects)
```

## Trade-offs

Encapsulating transitions makes phase-specific behavior testable. It adds types or tables and makes recovery versioning important. Treat emitted effects as retriable, and keep state changes and their outgoing effects consistent on failure.

## Commonly Used With

- [Command](command.md) provides named events such as cancel or accept for state-specific handling.
- [Observer](observer.md) can notify clients once the new phase is committed.
- [Transactional Outbox](transactional-outbox.md) can store the outgoing effect in the same transaction as the phase change.
