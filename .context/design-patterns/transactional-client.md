---
type: Design Pattern
title: "Transactional Client"
description: "Use the messaging system’s transaction boundary to commit or roll back related messaging operations together."
family: EIP
category: Messaging Endpoints
tags: ["transactions","atomicity","acknowledgment"]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: eip
    resource: https://www.enterpriseintegrationpatterns.com/patterns/messaging/TransactionalClient.html
    title: "Transactional Client"
    author: "human:hohpe-woolf"
---

# Transactional Client

## When to use

Use when a client must coordinate receiving and sending messages on a transport that explicitly supports the required transaction scope.

## Abstract implementation

On a transactional queue manager, begin a transaction, receive a work item and send the next-stage item in the same session. Commit acknowledges the input and makes the output visible together. Rollback makes the input available again.

Example — `begin → receive A → send B → commit`; a rollback makes A eligible again.

## Concrete implementation

For a future transactional transport adapter in Go, a relay dispatcher could consume a delivery attempt and enqueue a retry record within that broker’s local transaction. Its adapter contract would need to demonstrate atomic consume-and-send. In the proposed PostgreSQL/JetStream path, commit a receipt and outbox row in PostgreSQL, then acknowledge the input.

## Trade-offs

A broker transaction covers its documented resources. An HTTP provider call or a separate database write needs its own recovery protocol. Choosing this pattern adds coupling to broker capabilities.

## Commonly Used With

- [Transactional Outbox](transactional-outbox.md) covers the separate database-to-broker boundary.
- [Idempotent Receiver](idempotent-receiver.md) recognizes duplicate inputs when an acknowledgement is uncertain.
