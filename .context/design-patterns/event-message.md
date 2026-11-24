---
type: Design Pattern
title: "Event Message"
description: "A publisher announces that a specific occurrence has already taken place."
family: EIP
category: "Message Construction"
tags: ["eip","events","notification"]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: eip
    resource: https://www.enterpriseintegrationpatterns.com/patterns/messaging/EventMessage.html
    title: "Event Message"
    author: 'human:hohpe-woolf'
---

# Event Message

## When to use

Other components may react to a state change, while the component making the change can complete its own transaction independently.

## Abstract implementation

Name the past occurrence and include enough identity and context for a subscriber to associate it with its own state. A stable event ID allows reprocessing, and an entity revision can help detect gaps or stale updates.

`commit(run42.closed) → publish(RunClosed{eventID: 19, runID: 42, revision: 8})`

## Concrete implementation

When a run closes, a coordinator could commit its terminal state alongside an outbox row containing `RunClosed`, a run ID, revision and event ID. An authorized reporting subscriber applies the event to its projection and records the event ID as processed.

## Trade-offs

A subscriber may see duplicate or late events, and replay may encounter schemas from older emitters. Avoid putting private transcript content in a general operational event. Decide how a consumer repairs a missed change.

## Commonly Used With

- Each authorized observer can receive its own copy of the occurrence. [Publish-Subscribe Channel](publish-subscribe-channel.md)
- Durable handoffs preserve events that a downstream projection needs for recovery. [Guaranteed Delivery](guaranteed-delivery.md)
