---
type: Design Pattern
title: Content Enricher
description: "An enricher adds missing information from an authoritative source before a message proceeds."
family: EIP
category: Message Transformation
tags: [eip, message-transformation, data-enrichment]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: eip
    resource: https://www.enterpriseintegrationpatterns.com/patterns/messaging/DataEnricher.html
    title: Content Enricher
    author: 'human:hohpe-woolf'
---

# Content Enricher

## When to use

A connector check-in provides a device identifier, but the host's admission decision also needs the device's current enrollment and allowance.

## Abstract implementation

Validate the lookup key, retrieve the missing facts, and add their values and provenance to an internal message. Define how to handle lookup failures and stale records.

`{itemID} + lookup(itemID).unit → {itemID, unit}` when the lookup succeeds.

## Concrete implementation

After authenticating a caller, an admission handler could load its active device binding and current grant revision from host-local state. Attach the permitted harness and remaining allowance to an internal reservation request. When reserving, compare the revision and charge against current state atomically so concurrent requests cannot overspend.

## Trade-offs

A lookup adds latency and can create time-of-check races. Cache descriptive labels when appropriate and reread mutable authorization facts at the point of use.

## Commonly Used With

- [Content Filter](./content-filter.md) — Strip enriched fields that a downstream recipient does not need.
- [Message Filter](./message-filter.md) — Drop requests whose required enrichment cannot be validated.
