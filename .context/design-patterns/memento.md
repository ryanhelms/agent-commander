---
type: Design Pattern
title: Memento
description: "A memento captures an object's state in an opaque snapshot that the originating object can later restore."
family: GoF
category: Behavioral
tags:
  - snapshots
  - recovery
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: gof
    resource: https://www.informit.com/store/design-patterns-elements-of-reusable-object-oriented-9780201633610
    title: "Design Patterns: Elements of Reusable Object-Oriented Software"
    author: "human:gamma-helm-johnson-vlissides"
---

# Memento

## When to use

Use a memento when a caller needs to pause, restore or undo local state but should not depend on its representation. It fits a reader's cursor, filters and selection better than an external action that may already have occurred.

## Abstract implementation

The originator creates and restores a snapshot. A caretaker retains that snapshot and knows when to return it, without editing its fields. Stamp snapshots with the identity and version they describe and define which state is safe to restore.

For example, `saved = editor.capture()` gives an undo stack an opaque value. `editor.restore(saved)` lets the editor interpret its saved selection and text.

## Concrete implementation

A proposed relay transcript reader could save its local position before opening a cross-run request. Returning to the original trace would restore the visible worker and cursor only after current access and retention were checked.

```text
bookmark = reader.capture()
stack.push(bookmark)
openLinkedRequest(request)
saved = stack.pop()
reader.restore(saved, currentActor, currentRetentionFloor)
```

## Trade-offs

Snapshots cost storage and can become invalid when records expire. An old snapshot must never restore a revoked grant, an expired input lease or a provider-side action. Return a visible restore failure when the bookmarked event has expired.

## Commonly Used With

- [Command](command.md) can hold a memento to undo a reversible local action.
- [Iterator](iterator.md) can capture its traversal position without exposing its pagination internals.
