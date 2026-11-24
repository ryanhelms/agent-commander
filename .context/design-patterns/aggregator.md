---
type: Design Pattern
title: Aggregator
description: "An aggregator collects related messages until a completion rule permits one combined result."
family: EIP
category: Message Routing
tags: [eip, message-routing, aggregation]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: eip
    resource: https://www.enterpriseintegrationpatterns.com/patterns/messaging/Aggregator.html
    title: Aggregator
    author: 'human:hohpe-woolf'
---

# Aggregator

## When to use

A coordinator needs one report from independent workers whose findings can arrive late, out of order, or twice.

## Abstract implementation

Choose a correlation key, a completion rule, and a combination function. Retain each distinct contribution until the rule or deadline is satisfied.

`expected[K] = {A, B}`. Receiving `A, A, B` yields a single aggregate for `K` with two distinct contributions.

## Concrete implementation

On the coordinator host, store one result per `(reviewID, childID)` and reject IDs outside the original manifest. In one transaction, insert the contribution, check whether all expected children have finished, and mark the report ready only once. Assemble findings in manifest order.

## Trade-offs

Waiting for every contributor can stall a run. A deadline or quorum changes the meaning of completeness, so identify missing children in partial reports and define what happens to late arrivals.

## Commonly Used With

- [Splitter](./splitter.md) — Supply the expected child set for the aggregate.
- [Correlation Identifier](./correlation-identifier.md) — Associate each result with its parent independently of arrival order.
