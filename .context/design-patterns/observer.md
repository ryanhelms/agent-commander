---
type: Design Pattern
title: Observer
description: "An observer subscribes to changes from a subject and can detach without changing the subject's behavior."
family: GoF
category: Behavioral
tags:
  - subscriptions
  - events
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: gof
    resource: https://www.informit.com/store/design-patterns-elements-of-reusable-object-oriented-9780201633610
    title: "Design Patterns: Elements of Reusable Object-Oriented Software"
    author: "human:gamma-helm-johnson-vlissides"
---

# Observer

## When to use

Choose this when independent in-process consumers should react to a state change without the producer knowing their concrete types. A wall tile and an attention indicator may both observe one worker's question state.

## Abstract implementation

The subject defines a subscription contract and publishes after its state changes. Observers receive either the changed value or a notification prompting them to read it. Specify ordering, ownership of subscription lifetimes, and behavior for slow observers.

For example, `subscription = sensor.subscribe(display.update)` connects the display, and `subscription.cancel()` detaches it when the display closes.

## Concrete implementation

A proposed relay client could expose a per-worker observation API that atomically returns the initial state and a buffered stream of later revisions. Closing a window would cancel its subscription. If revisions are dropped, the consumer would request a fresh snapshot.

```text
initial, changes, cancel = workers.observe(workerID)
defer cancel()
render(initial)
for change in changes:
    if change.hasGap: render(workers.snapshot(workerID))
    else: render(change.value)
```

## Trade-offs

Direct notifications keep views responsive, but issuing callbacks under a state lock risks deadlock and reentrancy. Hand off notifications after publication and put a bound on per-observer buffers. Durable cross-host replay requires its own protocol.

## Commonly Used With

- [Mediator](mediator.md) can publish state changes after coordinating several participants.
- [State](state.md) gives observers an explicit value for the transition they are displaying.
- [Publish-Subscribe Channel](publish-subscribe-channel.md) can distribute analogous notifications across process boundaries.
