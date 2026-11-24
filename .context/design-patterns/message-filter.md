---
type: Design Pattern
title: Message Filter
description: "A filter forwards messages that satisfy a predicate and discards the rest."
family: EIP
category: Message Routing
tags: [eip, message-routing, subscription-filtering]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: eip
    resource: https://www.enterpriseintegrationpatterns.com/patterns/messaging/Filter.html
    title: Message Filter
    author: 'human:hohpe-woolf'
---

# Message Filter

## When to use

A dashboard already authorized to observe a worker needs only that worker's terminal state transitions.

## Abstract implementation

Evaluate each message independently. Forward the original message when it matches. Define what an intentional omission means so consumers can distinguish filtering from transport loss.

`state = completed → forward(original)`, then `state = working → drop`.

## Concrete implementation

On the host, check the observation grant, then compare each projected event's worker ID with the subscription. For a completion-only subscription, forward `completed` and `failed` transitions. Recheck the grant while the subscription is open so revocation stops delivery.

## Trade-offs

Early filtering saves bandwidth. Missed matches can go unnoticed downstream, so count exclusions by rule version and exercise boundary cases.

## Commonly Used With

- [Content-Based Router](./content-based-router.md) — Route into several destinations when each needs a different subset.
- [Content Filter](./content-filter.md) — Project fields after selecting the messages that should reach a consumer.
