---
type: Design Pattern
title: Composed Message Processor
description: "A composed processor splits a composite input, routes its parts, and aggregates their outcomes."
family: EIP
category: Message Routing
tags: [eip, message-routing, composite-processing]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: eip
    resource: https://www.enterpriseintegrationpatterns.com/patterns/messaging/DistributionAggregate.html
    title: Composed Message Processor
    author: 'human:hohpe-woolf'
---

# Composed Message Processor

## When to use

One review request contains code, documentation, and generated files. They require different checks but must yield one overall result.

## Abstract implementation

Split the input into identified parts, select a processor for each kind of part, then aggregate the expected outcomes under the original request ID.

`batch → split → route each item to its checker → aggregate by batch ID → report`.

## Concrete implementation

A Go coordinator can persist a change manifest, route documentation to a link checker and source files to a static-analysis worker, and record why generated files were skipped. Complete the report only when every manifest entry has a terminal outcome. Submit remote reservations through each receiver's normal admission checks.

## Trade-offs

Specialized handlers can evolve independently, but the orchestrator must define completion and bounds on parallelism. Stable part IDs avoid repeating expensive checks on retry.

## Commonly Used With

- [Content-Based Router](./content-based-router.md) — Select each part's handler using its declared kind.
- [Aggregator](./aggregator.md) — Combine the terminal outcomes specified in the manifest.
