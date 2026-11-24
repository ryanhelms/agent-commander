---
type: Design Pattern
title: Mediator
description: "A mediator coordinates a set of participants that would otherwise need detailed knowledge of each other."
family: GoF
category: Behavioral
tags:
  - coordination
  - decisions
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: gof
    resource: https://www.informit.com/store/design-patterns-elements-of-reusable-object-oriented-9780201633610
    title: "Design Patterns: Elements of Reusable Object-Oriented Software"
    author: "human:gamma-helm-johnson-vlissides"
---

# Mediator

## When to use

Use a mediator when several peers must react to the same interaction and direct callbacks create circular ownership. For example, a requester, approver and disconnect watcher can all affect one pending decision.

## Abstract implementation

Participants send interaction events to a mediator. The mediator applies the collaboration rules and directs updates to participants. Each participant still owns its own local behavior. Keep the mediator's responsibility small enough to describe as one collaboration.

For example, `dialog.changed(countryField)` lets the dialog update the region selector and submit button together. Neither control needs a reference to the others.

## Concrete implementation

An envisioned relay decision mediator could serialize races between a human reply and a worker withdrawing its question. The first valid transition would record the result; committed notifications would tell both sides which event settled the question.

```text
on decisionEvent(event):
    transaction:
        question = lockQuestion(event.questionID)
        next = question.applyAuthorized(event)
        if next.changed:
            save(next)
            enqueueNotifications(next)
```

## Trade-offs

A mediator removes pairwise dependencies but can become the place every unrelated policy accumulates. Keep the durable question state and access rules explicit so a replacement mediator can recover the same result.

## Commonly Used With

- [State](state.md) can represent the allowed transitions the mediator coordinates.
- [Observer](observer.md) can deliver committed updates from the mediator to interested participants.
