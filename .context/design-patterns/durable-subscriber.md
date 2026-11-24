---
type: Design Pattern
title: "Durable Subscriber"
description: "Keep a subscription’s delivery position across disconnects so retained messages can be resumed."
family: EIP
category: Messaging Endpoints
tags: ["persistence","reconnect","subscription"]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: eip
    resource: https://www.enterpriseintegrationpatterns.com/patterns/messaging/DurableSubscription.html
    title: "Durable Subscriber"
    author: "human:hohpe-woolf"
---

# Durable Subscriber

## When to use

Use when a subscriber may go offline but is expected to receive selected events within a defined retention window.

## Abstract implementation

Assign each independent subscriber a stable identity. The broker tracks its acknowledged position and maintains eligible outstanding deliveries until acknowledgement or retention expiry.

Example — `resume(subscription_id) → deliver retained item after last acknowledged position`

## Concrete implementation

Give a Go delivery service a named JetStream durable consumer for a bounded shard of queued operations. On restart it resumes from its acknowledged position, rechecks the destination grant and expiry, then forwards the sealed child. Track the destination device’s receipt separately from the broker consumer’s position.

## Trade-offs

Durability incurs storage and cleanup costs. Broker retention can expire while a device is offline. Define how to report an expired child and bound the number of consumers independently of the number of registered devices.

## Commonly Used With

- [Guaranteed Delivery](guaranteed-delivery.md) supplies persistence under the selected broker failure and retention policy.
- [Message Expiration](message-expiration.md) bounds how long an offline action remains eligible.
