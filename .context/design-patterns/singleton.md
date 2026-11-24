---
type: Design Pattern
title: Singleton
description: "A singleton controls construction so callers inside a defined runtime share one instance."
family: GoF
category: Creational
tags:
  - construction
  - lifecycle
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: gof
    resource: https://www.informit.com/store/design-patterns-elements-of-reusable-object-oriented-9780201633610
    title: "Design Patterns: Elements of Reusable Object-Oriented Software"
    author: "human:gamma-helm-johnson-vlissides"
---

# Singleton

## When to use

Choose this only when two instances inside a defined scope would violate an invariant. Name the scope precisely. One process can own a single handler for its shutdown signal, while different processes can legitimately have different handlers.

## Abstract implementation

Keep construction private, publish one synchronized accessor, and define who initializes and shuts the instance down. Passing that instance into consumers at composition time still gives them explicit dependencies.

For example, calls to `ProcessSignals.instance()` from the listener and scheduler return the same signal manager until that process exits.

## Concrete implementation

An envisioned Go relay executable could install process signal handling once. Its entry point would obtain the shared shutdown context and inject it into the listener and worker pool. Separate command invocations would each own their own context.

```text
shutdownContext():
    once.do:
        shared = subscribeProcessSignals(INTERRUPT, TERMINATE)
    return shared.context

ctx = shutdownContext()
serve(ctx, workers)
```

## Trade-offs

Process-wide lifetime complicates parallel tests and replacement during reload. Construct and inject explicit instances when isolation is desirable. A singleton cannot enforce a spending limit across relay replicas.

## Commonly Used With

- [Facade](facade.md) can receive the process-owned resource as a constructor dependency.
- [Observer](observer.md) lets multiple components subscribe to the single owner's shutdown notification.
