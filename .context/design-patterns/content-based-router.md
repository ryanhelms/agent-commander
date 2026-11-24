---
type: Design Pattern
title: Content-Based Router
description: "A router selects a destination by evaluating fields in each message."
family: EIP
category: Message Routing
tags: [eip, message-routing, routing-rules]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: eip
    resource: https://www.enterpriseintegrationpatterns.com/patterns/messaging/ContentBasedRouter.html
    title: Content-Based Router
    author: 'human:hohpe-woolf'
---

# Content-Based Router

## When to use

Messages share an entry point, but different handlers implement each kind of operation. Observing a worker and reserving capacity are two such operations.

## Abstract implementation

Define mutually exclusive routing predicates over versioned messages. Evaluate each message, pick one destination, and give unmatched versions or operations an explicit outcome.

`kind = notice → notify`, `kind = query → lookup`, `unknown kind → reject`.

## Concrete implementation

At the receiving host, authenticate and decrypt a request, then switch on its validated `Kind`. Dispatch `ObserveWorker` to the observation handler and `ReserveCapacity` to admission control. Each handler checks its own grant. An edge without the decryption key can route using an allowed outer destination ID.

## Trade-offs

Small rule tables are easy to inspect. Overlapping or unversioned predicates can silently send new commands to the wrong handler.

## Commonly Used With

- [Message Filter](./message-filter.md) — Drop messages outside an accepted subset before dispatch.
- [Dynamic Router](./dynamic-router.md) — Let recipients register capabilities when a fixed destination table becomes inadequate.
