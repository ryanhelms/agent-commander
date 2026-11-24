---
type: Design Pattern
title: "Competing Consumers"
description: "Share one logical subscription across workers that can each handle any work item."
family: EIP
category: Messaging Endpoints
tags: ["load-balancing","queue","horizontal-scaling"]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: eip
    resource: https://www.enterpriseintegrationpatterns.com/patterns/messaging/CompetingConsumers.html
    title: "Competing Consumers"
    author: "human:hohpe-woolf"
---

# Competing Consumers

## When to use

Use when dispatchers are interchangeable and throughput needs to grow by adding replicas. First decide how many *logical deliveries* the operation requires.

## Abstract implementation

A print farm puts one item on a shared queue per requested copy. Idle printers independently claim work. A printer failure can redeliver an item, so completion is keyed by copy ID.

Example — `copy A → shared queue → one available printer`; another attempt keeps copy A’s identity.

## Concrete implementation

For a request to Bob, Cara and Dev, record three different child delivery IDs before publishing. Multiple Go dispatchers share one durable pull consumer. A dispatcher claiming Cara’s child resolves her device’s current tunnel owner and forwards only that child. A restarted dispatcher continues with the same child ID.

## Trade-offs

Identical workers distribute attempts, while a specific live socket belongs to one edge. Parallel consumers can reorder deliveries and redeliver after timeouts. Preserve ordering only at scopes that require it.

## Commonly Used With

- [Recipient List](recipient-list.md) creates the independently addressed deliveries that the pool balances.
- [Idempotent Receiver](idempotent-receiver.md) absorbs duplicates after a worker or acknowledgement fails.
