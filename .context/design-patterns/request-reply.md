---
type: Design Pattern
title: "Request-Reply"
description: "Two messages connect a request to a subsequently delivered answer."
family: EIP
category: "Message Construction"
tags: ["eip","conversation","responses"]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: eip
    resource: https://www.enterpriseintegrationpatterns.com/patterns/messaging/RequestReply.html
    title: "Request-Reply"
    author: 'human:hohpe-woolf'
---

# Request-Reply

## When to use

A caller needs an answer from a remote participant while using channels that deliver each direction independently.

## Abstract implementation

Register the pending request before sending it. Supply a reply route and a conversation key. The receiver sends the outcome separately, and the caller matches it to a live request or applies its late-reply policy.

`caller sends Lookup(q7) → responder sends Found(inReplyTo=q7) → caller resolves pending[q7]`

## Concrete implementation

A Go client could subscribe to its authorized inbox, record a pending status query with a deadline, then publish the sealed query. The worker returns an authenticated reply referencing the query ID. The client completes the waiting call only after checking the responder and correlation.

## Trade-offs

A caller may time out even though the responder completed its work. Two messages also mean two authorization decisions and possibly different delivery delays. Bound the table of pending requests and define how duplicates are handled.

## Commonly Used With

- The requester supplies a route on which it can receive the answer. [Return Address](return-address.md)
- A reply carries the key needed to complete the correct waiting call. [Correlation Identifier](correlation-identifier.md)
