---
type: Design Pattern
title: Scatter-Gather
description: "A requester sends a query to multiple recipients and combines their replies under a completion policy."
family: EIP
category: Message Routing
tags: [eip, message-routing, parallel-query]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: eip
    resource: https://www.enterpriseintegrationpatterns.com/patterns/messaging/BroadcastAggregate.html
    title: Scatter-Gather
    author: 'human:hohpe-woolf'
---

# Scatter-Gather

## When to use

A user wants to compare available capacity across a small number of friends who have opted into availability queries.

## Abstract implementation

Send one logical query to eligible recipients. Correlate each answer with both the query and its respondent. Gather until all have replied, a quorum is reached, or the deadline expires.

`query(Q) → {A, B, C}`. At the deadline, fold the replies from `A` and `C` into a result that lists `B` as missing.

## Concrete implementation

Send a nonce-bound availability request to each selected host with the same deadline. Deduplicate replies per host and mark nonresponders explicitly. Once the user chooses an offer, submit one reservation to that host. The host rechecks entitlement, budget, and availability at reservation time.

## Trade-offs

Quick responses can bias selection toward nearby hosts. A reply is a snapshot that can age before use. Bound the fan-out and avoid treating a missing reply as zero capacity.

## Commonly Used With

- [Recipient List](./recipient-list.md) — Identify the hosts the requester may query.
- [Aggregator](./aggregator.md) — Apply the deadline and produce the comparison.
