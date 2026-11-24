---
type: Design Pattern
title: Recipient List
description: "A dispatcher sends a separate copy of a message to each selected recipient."
family: EIP
category: Message Routing
tags: [eip, message-routing, fan-out]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: eip
    resource: https://www.enterpriseintegrationpatterns.com/patterns/messaging/RecipientList.html
    title: Recipient List
    author: 'human:hohpe-woolf'
---

# Recipient List

## When to use

A project owner wants to notify the devices currently entitled to a shared worker, and that set varies by worker.

## Abstract implementation

Resolve the recipient set for one message, eliminate duplicates, then dispatch to each recipient. Record each dispatch independently when partial delivery matters.

`recipients(event) = {A, C}` produces `deliver(event, A)` and `deliver(event, C)`.

## Concrete implementation

On the sending device, resolve current worker share grants to device IDs. Seal a notification in each device's established encryption context. Track delivery under `(eventID, deviceID)` and retry only recipients whose grant is still valid. The relay forwards separately addressed frames.

## Trade-offs

Per-recipient encryption and delivery grow with list size. Membership can change while sending, so define the treatment of outstanding copies when access is revoked.

## Commonly Used With

- [Envelope Wrapper](./envelope-wrapper.md) — Address each copy independently of the underlying event.
- [Scatter-Gather](./scatter-gather.md) — Collect replies when a fan-out needs a combined answer.
