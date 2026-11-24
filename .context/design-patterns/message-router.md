---
type: Design Pattern
title: "Message Router"
description: "An intermediary selects the next channel for a message using routing information and a routing rule."
family: EIP
category: "Messaging Systems"
tags: ["eip","dispatch","routing"]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: eip
    resource: https://www.enterpriseintegrationpatterns.com/patterns/messaging/MessageRouter.html
    title: "Message Router"
    author: 'human:hohpe-woolf'
---

# Message Router

## When to use

A producer should address one entry point while an independently managed rule selects the destination.

## Abstract implementation

Read the minimum routing metadata, resolve it against a route table and forward the message to the chosen channel. Define the outcome for an unmatched route. Preserve identity across forwarding and retry.

`next = routes[envelope.destination]; forward(next, envelope)`

## Concrete implementation

A relay can resolve an authenticated destination device ID to a regional mailbox. It checks that the sender may reach that device before forwarding the original sealed envelope. An unknown device produces a routing failure tied to the message ID.

## Trade-offs

A routing table centralizes placement decisions and can become a bottleneck or stale during moves. Route changes require a policy for already accepted deliveries.

## Commonly Used With

- Each possible destination is a channel with its own delivery policy. [Message Channel](message-channel.md)
- Exhausted deliveries can retain routing failure evidence for an operator. [Dead Letter Channel](dead-letter-channel.md)
