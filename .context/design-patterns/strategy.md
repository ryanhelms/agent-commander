---
type: Design Pattern
title: Strategy
description: "A strategy makes a replaceable algorithm an explicit dependency of the operation that uses it."
family: GoF
category: Behavioral
tags:
  - policy
  - algorithms
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: gof
    resource: https://www.informit.com/store/design-patterns-elements-of-reusable-object-oriented-9780201633610
    title: "Design Patterns: Elements of Reusable Object-Oriented Software"
    author: "human:gamma-helm-johnson-vlissides"
---

# Strategy

## When to use

Use a strategy when an operation is stable but two or more valid algorithms implement a particular decision. Choosing among already-eligible relay endpoints by latency or by regional preference is a suitable boundary.

## Abstract implementation

The context supplies a strategy with a fixed input contract. Each strategy computes an answer within the same constraints. The composition root selects which strategy applies. A single local calculation can remain a function until a second algorithm justifies the interface.

For example, `routePlanner.plan(start, end, wheelchairAccessible)` can accept a second route-cost strategy for a cyclist while retaining the same search and output contract.

## Concrete implementation

A proposed relay scheduler could obtain a snapshot of authorized, available hosts, then apply a ranking function selected by the project. Reservation would conditionally claim the chosen host and fail if it was no longer available.

```text
eligible = hosts.availableAndPermitted(grant, requirements)
if eligible.empty: return NoEligibleHost
rank = projectPolicy.hostRanking
host = rank.first(eligible, job)
return reservations.claimIfCurrent(host.id, host.revision, job.id)
```

## Trade-offs

Policies can be evaluated independently using the same input set. A strategy that mutates availability or bypasses eligibility makes its results hard to compare. Keep the final claim and reauthorization under the scheduler's control.

## Commonly Used With

- [Template Method](template-method.md) can delegate one variable step in its fixed sequence to a strategy.
- [Decorator](decorator.md) can use a strategy to decide when to retry or record an observation.
