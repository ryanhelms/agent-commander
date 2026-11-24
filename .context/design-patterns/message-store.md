---
type: Design Pattern
title: Message Store
description: "A message store retains selected message data for later querying independently of delivery."
family: EIP
category: System Management
tags: [eip, system-management, historical-query]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: eip
    resource: https://www.enterpriseintegrationpatterns.com/patterns/messaging/MessageStore.html
    title: Message Store
    author: 'human:hohpe-woolf'
---

# Message Store

## When to use

An owner needs to answer which reservation requests reached a terminal outcome yesterday, even when the live observation stream has advanced.

## Abstract implementation

Copy selected messages or projections into a queryable store indexed by stable identifiers and event time. Define access, retention, deduplication, and what a missing entry means.

`received(event7) → store.upsert(event7.id, projection)`. A later query reads that projection independently of the live stream.

## Concrete implementation

On the receiving host, record accepted operation facts such as worker ID, operation ID, transition, and time in the same local transaction as the transition or through its transactional outbox. Query that projection using the caller's current grant. Keep prompt bodies out of the cross-tenant reporting path.

## Trade-offs

A queryable history increases write volume and retention obligations. Asynchronous copies can lag, so distinguish an incomplete reporting projection from the authoritative execution receipt.

## Commonly Used With

- [Wire Tap](./wire-tap.md) — Feed a best-effort diagnostic store from a copy when loss is acceptable.
- [Content Filter](./content-filter.md) — Persist the minimum event projection needed for the supported queries.
