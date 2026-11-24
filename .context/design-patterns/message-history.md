---
type: Design Pattern
title: Message History
description: "Message history records the processing path of an individual message."
family: EIP
category: System Management
tags: [eip, system-management, traceability]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: eip
    resource: https://www.enterpriseintegrationpatterns.com/patterns/messaging/MessageHistory.html
    title: Message History
    author: 'human:hohpe-woolf'
---

# Message History

## When to use

A delivery failure could have occurred during ingress, handoff between edges, or receiver admission. Aggregate counters cannot identify which boundaries one attempt crossed.

## Abstract implementation

Have participating components append a stage ID and local outcome to a bounded history for that message. Preserve the operation ID across retries and distinguish each delivery attempt.

`attempt42.history = [(ingress, accepted), (egress, forwarded)]` records two observations of one attempt.

## Concrete implementation

For a proposed relay hop envelope, an edge can append `{attemptID, stage, edgeID, outcome}` to a permitted outer history field before forwarding. At the destination, keep the admission decision in the host-local receipt. Join those histories using the attempt ID, preserving the distinction between observing a hop and proving execution.

## Trade-offs

Per-hop detail consumes space and exposes topology. Cap hop count, avoid sensitive payload fields, and treat remote timestamps as approximate if clocks are unsynchronized.

## Commonly Used With

- [Correlation Identifier](./correlation-identifier.md) — Link attempts and local receipts while preserving their distinct identities.
- [Envelope Wrapper](./envelope-wrapper.md) — Separate mutable, bounded route history from the authenticated inner command.
