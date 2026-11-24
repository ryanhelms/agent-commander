---
type: Design Pattern
title: Iterator
description: "An iterator exposes a traversal while keeping collection storage and cursor mechanics inside the collection boundary."
family: GoF
category: Behavioral
tags:
  - traversal
  - pagination
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: gof
    resource: https://www.informit.com/store/design-patterns-elements-of-reusable-object-oriented-9780201633610
    title: "Design Patterns: Elements of Reusable Object-Oriented Software"
    author: "human:gamma-helm-johnson-vlissides"
---

# Iterator

## When to use

Use an iterator when callers need to consume a collection incrementally and should not know whether its storage is an array, database or paged remote API. Specify the order and what concurrent insertion or deletion means.

## Abstract implementation

An aggregate creates a traversal object. The object stores position and returns one value, a terminal result, or an error at each advance. Separate iterators over the same aggregate maintain independent positions.

For example, `cursor = library.booksByAuthor(name)` creates a traversal, and each `cursor.next()` returns the next matching book in its specified order.

## Concrete implementation

A proposed relay history client could pin an upper sequence number when it opens a traversal. A reconnect could resume after the last consumed sequence, scoped to the same worker and snapshot. A retention gap would return an explicit error.

```text
history = relay.history(workerID, after = cursor, until = snapshotHighWater)
for event in history:
    consume(event)
    checkpoint(event.sequence)
if history.error: report(history.error)
```

## Trade-offs

A snapshot bound makes traversal repeatable but omits newer events until the next traversal. A live tail has different semantics. Keep the cursor scoped to the stream and revalidate access on every page.

## Commonly Used With

- [Composite](composite.md) can provide an iterator over the leaves of a nested collection.
- [Memento](memento.md) can represent the versioned cursor required to resume a paused traversal.
