---
type: Design Pattern
title: "Publish-Subscribe Channel"
description: "A published message reaches each eligible subscription independently."
family: EIP
category: "Messaging Channels"
tags: ["eip","fan-out","subscriptions"]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: eip
    resource: https://www.enterpriseintegrationpatterns.com/patterns/messaging/PublishSubscribeChannel.html
    title: "Publish-Subscribe Channel"
    author: 'human:hohpe-woolf'
---

# Publish-Subscribe Channel

## When to use

Multiple independent applications need the same notification, and publishers should be able to add an observer without changing their send logic.

## Abstract implementation

Publish to a topic. Each subscription receives a logical copy or an independent position in a shared log. Track acknowledgements and recovery per subscription according to the retention policy.

`publish(RunClosed(42)) → usageSubscription receives #42 + auditSubscription receives #42`

## Concrete implementation

A coordinator could publish sanitized `RunClosed` events to an authorized topic. The usage projector and activity counter would use different subscriptions. Two replicas of the usage projector would share its subscription so they can divide that projector’s work.

## Trade-offs

A slow subscription may accumulate its own backlog. Retained events expose history to any newly authorized reader with replay rights. For private group messages, enforce recipient and key eligibility before distributing readable content.

## Commonly Used With

- A fact about a completed run can feed several independent projections. [Event Message](event-message.md)
- Replicas can divide work inside each subscriber group. [Point-to-Point Channel](point-to-point-channel.md)
