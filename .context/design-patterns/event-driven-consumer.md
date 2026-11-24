---
type: Design Pattern
title: "Event-Driven Consumer"
description: "Register a handler that the messaging endpoint invokes when a matching message arrives."
family: EIP
category: Messaging Endpoints
tags: ["events","push","subscriptions"]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: eip
    resource: https://www.enterpriseintegrationpatterns.com/patterns/messaging/EventDrivenConsumer.html
    title: "Event-Driven Consumer"
    author: "human:hohpe-woolf"
---

# Event-Driven Consumer

## When to use

Use when a consumer should react promptly and its transport can invoke a callback or stream handler.

## Abstract implementation

A shipping dashboard registers for parcel status changes. Its callback schedules a bounded update and returns promptly so a slow render cannot block reception of later changes.

Example — `subscribe(shipment_changed, enqueue_dashboard_update)`

## Concrete implementation

A Go edge watches device-presence changes. A callback replaces the latest visible status for the device in a bounded buffer and wakes authorized tray subscribers. On a subscription gap the edge refreshes a presence snapshot. Receiving presence consumes no model budget.

## Trade-offs

Slow callbacks can halt other subscriptions. Coalescing works for replaceable state such as presence, whereas durable commands require explicit acceptance, processing and recovery.

## Commonly Used With

- [Publish-Subscribe Channel](publish-subscribe-channel.md) distributes changes to independent observers.
- [Message Filter](message-filter.md) lets a consumer act on the relevant event types.
