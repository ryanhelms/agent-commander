---
type: Design Pattern
title: Factory Method
description: "A factory method lets a specialized creator choose a product while the shared workflow uses its common interface."
family: GoF
category: Creational
tags:
  - construction
  - extensibility
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: gof
    resource: https://www.informit.com/store/design-patterns-elements-of-reusable-object-oriented-9780201633610
    title: "Design Patterns: Elements of Reusable Object-Oriented Software"
    author: "human:gamma-helm-johnson-vlissides"
---

# Factory Method

## When to use

Use a factory method when several implementations share a lifecycle but construct different products within it. For example, local and remote session watchers might share the reconnect loop while opening different event readers.

## Abstract implementation

Define the product interface and a creation hook on the creator. The shared operation calls that hook when a fresh product is needed. In Go, a creator can delegate its hook to an injected interface method instead of relying on subclassing.

For example, a shared `importFile(path)` operation calls `creator.openReader(path)` before parsing. A compressed-file creator supplies a decompressing reader at that point.

## Concrete implementation

A proposed Go relay watcher could own replay and cancellation while each host watcher supplies a new reader tied to that host and cursor. Each reconnect gets a new reader. Reader creation errors return through the same workflow.

```text
watch(ctx, creator, cursor):
    reader = creator.openReader(ctx, cursor)
    defer reader.close()
    for event in reader:
        cursor = persistAndAcknowledge(event)
```

## Trade-offs

A creation hook keeps reconnect behavior consistent across products. A broad hook that also manages cursors or persistence would fragment the lifecycle. A direct constructor is simpler when the product type is fixed.

## Commonly Used With

- [Template Method](template-method.md) can define the surrounding workflow and call the creation hook at a fixed step.
- [Abstract Factory](abstract-factory.md) groups several related creation operations when a single product hook is insufficient.
