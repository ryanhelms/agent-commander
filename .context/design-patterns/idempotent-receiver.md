---
type: Design Pattern
title: "Idempotent Receiver"
description: "Recognize repeat attempts or design an operation whose repeated application has the same effect."
family: EIP
category: Messaging Endpoints
tags: ["retries","deduplication","receipts"]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: eip
    resource: https://www.enterpriseintegrationpatterns.com/patterns/messaging/IdempotentReceiver.html
    title: "Idempotent Receiver"
    author: "human:hohpe-woolf"
---

# Idempotent Receiver

## When to use

Use whenever disconnects, broker redelivery or duplicate client submissions can repeat an operation with side effects.

## Abstract implementation

A reservation handler inserts a row keyed by requester and operation ID and reserves stock in one transaction. A repeated request with the same immutable content returns the original receipt. An ID reused with different content is a conflict.

Example — `same key + same digest → saved receipt`; a different digest under that key is a conflict.

## Concrete implementation

For a paid relay child, enforce uniqueness on the authorized principal and child ID, bind the payload digest and reserve budget atomically. The receiver records intent before invoking the provider. After an ambiguous provider response, retry with the original provider idempotency key if supported or return an uncertain receipt for reconciliation.

## Trade-offs

A deduplication window that expires before clients finish retrying permits duplicate effects. A database commit alone cannot prove that an external provider executed exactly once. Retain receipts for the advertised retry window.

## Commonly Used With

- [Correlation Identifier](correlation-identifier.md) links a repeated attempt and its response to the original request.
- [Message Store](message-store.md) retains the authoritative outcome needed for recovery.
