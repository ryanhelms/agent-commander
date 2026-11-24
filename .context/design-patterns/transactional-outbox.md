---
type: Design Pattern
title: "Transactional Outbox"
description: "Record publication intent in the database transaction that changes domain state, then relay it to the broker."
family: Distributed Systems
category: Data and Consistency
tags: ["data","consistency","delivery","postgresql"]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: outbox
    resource: https://microservices.io/patterns/data/transactional-outbox.html
    title: "Transactional outbox"
    author: "human:chris-richardson"
---

# Transactional Outbox

## When to use

Use when durable acceptance in a database must lead to eventual publication despite a crash between commit and broker acknowledgement.

## Abstract implementation

A warehouse commits a shipment and an outbox event carrying the shipment ID in one transaction. A separate publisher claims committed events, obtains a broker acknowledgement, then marks them published. A retry preserves the event ID.

Example — `commit(shipment, outbox_event) → publish(event_id) → mark_published(event_id)`

## Concrete implementation

A Go request handler inserts the parent request and frozen child records plus an outbox entry for each durable dispatch in PostgreSQL. The publisher forwards each sealed child to JetStream with its stable ID. On restart it republishes any entry whose acknowledgement is missing. Authorization and expiry still apply to delivery.

## Trade-offs

A crash after broker acceptance and before the database update can publish twice. Bound retained ciphertext, monitor the age of the oldest unpublished entry, and serialize by aggregate sequence where causal order matters.

## Commonly Used With

- [Idempotent Receiver](idempotent-receiver.md) allows republication under the same identity.
- [Competing Consumers](competing-consumers.md) lets independent workers service the published child operations.
