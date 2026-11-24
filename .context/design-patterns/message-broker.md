---
type: Design Pattern
title: Message Broker
description: "A message broker centralizes routing and delivery between participants that evolve independently."
family: EIP
category: Message Routing
tags: [eip, message-routing, broker]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: eip
    resource: https://www.enterpriseintegrationpatterns.com/patterns/messaging/MessageBroker.html
    title: Message Broker
    author: 'human:hohpe-woolf'
---

# Message Broker

## When to use

Several clients need a stable address space for connecting to hosts whose live sockets move between edges.

## Abstract implementation

Accept messages through a stable interface, resolve logical destinations, and forward over registered connections. Select internal routing and transformation steps appropriate to the broker's trust boundary.

`deliver(logicalID, frame) → resolve(logicalID) → send(connection, frame)`.

## Concrete implementation

A Commander broker could accept an opaque frame for a host ID, locate its connected edge, and forward it through a bounded stream. Return offline if dispatch never started. A lost reply after dispatch leaves an uncertain outcome, recoverable using the receiving host's operation receipt. The receiver handles decryption and job admission.

## Trade-offs

Central routing simplifies clients but concentrates availability and metadata exposure. Separate tenant routes and enforce per-host limits to keep a slow destination from consuming the broker.

## Commonly Used With

- [Dynamic Router](./dynamic-router.md) — Keep logical destinations mapped to current connections.
- [Control Bus](./control-bus.md) — Manage broker enrollment and health independently of user traffic.
