---
type: Design Pattern
title: Control Bus
description: "A control bus carries administrative commands and operational status between messaging components."
family: EIP
category: System Management
tags: [eip, system-management, administration]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: eip
    resource: https://www.enterpriseintegrationpatterns.com/patterns/messaging/ControlBus.html
    title: Control Bus
    author: 'human:hohpe-woolf'
---

# Control Bus

## When to use

Relay operators need to drain an edge, inspect its health, or rotate its enrollment while ordinary work continues.

## Abstract implementation

Define a dedicated administrative interface with its own principals and message schemas. Address commands to specific components and correlate their replies. Model desired state separately from observed state.

`operator → Drain(component, generation) → component`, then `component → Drained(generation) → operator`.

## Concrete implementation

An operator service could send `DrainEdge{EdgeID, Generation, Deadline}` on a restricted subject. An authenticated edge records the generation, stops accepting new tunnels, and reports its active count until drained. Repeated commands for that generation return its current state. Only the receiving Commander owner can grant a friend permission to start jobs.

## Trade-offs

A common administrative path makes coordinated changes possible but concentrates privilege. Bound command scope and retain acknowledgements so operators can identify precisely which instances applied a change.

## Commonly Used With

- [Request-Reply](./request-reply.md) — Return each edge's observed result to the operator.
- [Dynamic Router](./dynamic-router.md) — Publish route withdrawals as an edge relinquishes its connections.
