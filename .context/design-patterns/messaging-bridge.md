---
type: Design Pattern
title: "Messaging Bridge"
description: "A bridge transfers messages between two messaging systems that cannot communicate directly."
family: EIP
category: "Messaging Channels"
tags: ["eip","interoperability","transport"]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: eip
    resource: https://www.enterpriseintegrationpatterns.com/patterns/messaging/MessagingBridge.html
    title: "Messaging Bridge"
    author: 'human:hohpe-woolf'
---

# Messaging Bridge

## When to use

Two established messaging installations must exchange a defined class of messages while retaining their own brokers, clients and administrative boundaries.

## Abstract implementation

Run a component with a receiving endpoint on one system and a sending endpoint on the other. Map addresses and transport headers, preserve the application identity and confirm the destination handoff before releasing the source delivery.

`receive(brokerA.jobs) → publish(brokerB.tasks, sameMessageID) → confirm(B) → acknowledge(A)`

## Concrete implementation

A Go bridge could consume an authorized tenant queue, look up one fixed destination subject and publish the sealed body with its original message ID. It acknowledges the source only after the destination confirms persistence. Reverse traffic uses a disjoint mapping to avoid loops.

## Trade-offs

Ordering, time-to-live and acknowledgement guarantees may differ across brokers. A timed-out publish can duplicate a message. Treat cross-system forwarding as a distinct permission and preserve signed application fields byte for byte.

## Commonly Used With

- Each side needs credentials and settlement behavior for its own transport. [Message Endpoint](message-endpoint.md)
- When representations differ, convert the permitted transport fields at the boundary. [Message Translator](message-translator.md)
