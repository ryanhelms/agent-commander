---
type: Design Pattern
title: "Selective Consumer"
description: "Receive only the messages matching a subscription’s selection criteria."
family: EIP
category: Messaging Endpoints
tags: ["selection","subscriptions","metadata"]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: eip
    resource: https://www.enterpriseintegrationpatterns.com/patterns/messaging/MessageSelector.html
    title: "Selective Consumer"
    author: "human:hohpe-woolf"
---

# Selective Consumer

## When to use

Use when different receivers on a channel need different subsets and selection can happen before delivery to that receiver.

## Abstract implementation

A consumer selects work tagged with its supported document format. Unselected work stays eligible for consumers with other capabilities, according to the channel’s delivery rules.

Example — `subscribe(work, where format == "pdf")`

## Concrete implementation

An edge’s internal status consumer subscribes to the allowed event subjects for its shard. Application policy separately verifies that each downstream observer may see that device’s presence. Use routing metadata already visible to the broker and keep encrypted prompt content opaque.

## Trade-offs

Selection is an efficiency feature. User-controlled selectors can be expensive or disclose other tenants’ identifiers. Build filters from trusted fields and enforce separate subject permissions and application grants.

## Commonly Used With

- [Message Filter](message-filter.md) can discard additional irrelevant events inside an authorized processing path.
- [Datatype Channel](datatype-channel.md) gives selectors stable event families to match.
