---
type: Design Pattern
title: Dynamic Router
description: "A router updates routing rules as participants advertise or withdraw capabilities."
family: EIP
category: Message Routing
tags: [eip, message-routing, dynamic-registration]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: eip
    resource: https://www.enterpriseintegrationpatterns.com/patterns/messaging/DynamicRouter.html
    title: Dynamic Router
    author: 'human:hohpe-woolf'
---

# Dynamic Router

## When to use

A host connector may reconnect to a new edge while clients continue addressing the same logical host.

## Abstract implementation

Have recipients register their capabilities on a control path. Update the routing table on registration, withdrawal, and expiration. Resolve the destination against this table for each request.

`register(regionA, handler7, revision3)` updates the table. A request for `regionA` resolves to `handler7` until that registration expires or changes.

## Concrete implementation

After authenticating an outbound connector, an edge could register `(hostID, edgeID, generation)` with a short lease. A forwarding edge resolves that lease. The destination edge verifies that it still owns the generation before using its connection. Removing or superseding the lease withdraws the route.

## Trade-offs

A stale table can point to a displaced connection. Fence old generations and distinguish retrying discovery from repeating a command whose dispatch is uncertain.

## Commonly Used With

- [Control Bus](./control-bus.md) — Carry authenticated route advertisements and withdrawals independently of worker traffic.
- [Message Expiration](./message-expiration.md) — Expire route registrations left behind by failed edges.
