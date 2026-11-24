---
type: Design Pattern
title: Chain of Responsibility
description: "A chain of responsibility gives a sequence of handlers an opportunity to handle a request or pass it onward."
family: GoF
category: Behavioral
tags:
  - dispatch
  - escalation
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: gof
    resource: https://www.informit.com/store/design-patterns-elements-of-reusable-object-oriented-9780201633610
    title: "Design Patterns: Elements of Reusable Object-Oriented Software"
    author: "human:gamma-helm-johnson-vlissides"
---

# Chain of Responsibility

## When to use

Use a chain when the sender knows the request but which participant can resolve it depends on context. For example, an escalation might go to an assignment owner, an on-call delegate, and then a project steward.

## Abstract implementation

Each handler accepts the same request and either resolves it, rejects it, or defers to its successor. The chain order and terminal behavior are explicit. Distinguish a handler that lacks jurisdiction from one that has made a binding rejection.

For example, `field.handleHelp(request)` can resolve help for that field or pass the request to its form, which can pass it to the enclosing window.

## Concrete implementation

An envisioned relay could select the first eligible contact to review a request. A handler would claim responsibility only if its actor may review that particular request. A policy denial would stop the chain, while absence of an on-call contact could defer to the next handler.

```text
for reviewer in orderedCandidates(request):
    decision = reviewer.consider(request)
    if decision is Deny: return Denied
    if decision is Claim: return recordReviewerOnce(request.id, reviewer.id)
return AwaitingOwner
```

## Trade-offs

Handlers are easy to add, but order and fallthrough affect outcomes. Record the handler that claimed or denied the request so a misrouted escalation can be diagnosed.

## Commonly Used With

- [Command](command.md) can carry the same immutable request through each handler.
- [Strategy](strategy.md) can select a candidate order using the incident type or on-call schedule.
