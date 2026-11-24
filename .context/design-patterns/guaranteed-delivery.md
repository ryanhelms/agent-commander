---
type: Design Pattern
title: "Guaranteed Delivery"
description: "Durable custody at each handoff allows accepted messages to survive component failure and resume delivery."
family: EIP
category: "Messaging Channels"
tags: ["eip","durability","acknowledgement"]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: eip
    resource: https://www.enterpriseintegrationpatterns.com/patterns/messaging/GuaranteedMessaging.html
    title: "Guaranteed Delivery"
    author: 'human:hohpe-woolf'
---

# Guaranteed Delivery

## When to use

Losing a message during a restart would lose a business obligation, and the sender can tolerate the cost of confirmation and recovery.

## Abstract implementation

Record the message durably before reporting acceptance. At each handoff, the outgoing holder releases its copy only after the next holder confirms durable receipt. Recover and resend outstanding records after a crash.

`persist(senderCopy) → confirmDurable(brokerCopy) → release(senderCopy)`

## Concrete implementation

A sender could insert an encrypted assignment and an outbox row in one SQL transaction. A dispatcher waits for durable broker confirmation before closing the row. The receiver commits the assignment and its message ID together before acknowledging delivery.

## Trade-offs

A lost acknowledgement produces duplicates, and an unavailable destination can retain work indefinitely. Disk failure tolerance depends on replication and confirmation policy. Define admission limits and the point at which an obligation is considered fulfilled.

## Commonly Used With

- A stable identifier survives retries across custody transfers. [Message](message.md)
- A permanent delivery failure needs a recoverable disposition. [Dead Letter Channel](dead-letter-channel.md)
