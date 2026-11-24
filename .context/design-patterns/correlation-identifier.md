---
type: Design Pattern
title: "Correlation Identifier"
description: "A reply carries a value that identifies the request to which it belongs."
family: EIP
category: "Message Construction"
tags: ["eip","matching","conversation"]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: eip
    resource: https://www.enterpriseintegrationpatterns.com/patterns/messaging/CorrelationIdentifier.html
    title: "Correlation Identifier"
    author: 'human:hohpe-woolf'
---

# Correlation Identifier

## When to use

Several requests may be outstanding, replies can arrive out of order, or multiple conversations share one reply channel.

## Abstract implementation

Assign a stable identifier to each request. Have the responder copy that identifier into a dedicated correlation field in each reply. The reply can have its own message ID for tracking or deduplication.

`send(req17), send(req18) → receive(replyToID=18) → resolve(pending[18])` leaves request 17 outstanding.

## Concrete implementation

A Go client could maintain `pending[(workspaceID, requestID)]` with an expected responder and deadline. On receipt, it verifies the reply, finds the matching entry, checks that responder and completes the waiter once. A replay finds the entry already fulfilled or expired.

## Trade-offs

Unique identifiers prevent accidental collisions but possession of an ID alone does not authenticate a response. Retaining waiters forever leaks memory. Multiple legitimate replies require an explicit completion rule.

## Commonly Used With

- Correlation allows many exchanges to share asynchronous transports. [Request-Reply](request-reply.md)
- A reply can reach one inbox and still identify the individual request within it. [Return Address](return-address.md)
