---
type: Design Pattern
title: "Fencing Token"
description: "Attach a monotonically increasing ownership generation to a lease and reject superseded owners at the protected operation."
family: Distributed Systems
category: Data and Consistency
tags: ["data","consistency","leases","ownership"]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: fencing
    resource: https://martin.kleppmann.com/2016/02/08/how-to-do-distributed-locking.html
    title: "How to do distributed locking"
    author: "human:martin-kleppmann"
---

# Fencing Token

## When to use

Use when an owner can pause, lose a lease and resume after a different owner has acquired the resource.

## Abstract implementation

On each successful acquisition, a coordinator issues a higher generation. Every protected write includes its generation. A resource that has accepted generation 18 rejects writes from generation 17 even if its former owner still has a connection.

Example — `write(resource, generation=17) → stale` after the resource accepts generation 18.

## Concrete implementation

For relay device D, a durable PostgreSQL ownership row advances from generation 41 on edge A to 42 on edge B. New protected dispatch claims verify D and generation 42 in the same transaction as the effect they authorize. D installs 42 before acknowledging readiness, and accepts frames only on its current session. Conditional removal by A with 41 cannot clear B’s registration.

## Trade-offs

A TTL bounds liveness reporting but cannot fence a delayed write. Every protected effect needs an enforcing endpoint. External provider calls without fencing support need scoped execution claims and durable reconciliation. Preserve monotonicity during backup restore and credential rotation.

## Commonly Used With

- [Dynamic Router](dynamic-router.md) updates the next hop as devices move between edges.
- [Idempotent Receiver](idempotent-receiver.md) prevents repeated attempts within a valid generation from duplicating a side effect.
