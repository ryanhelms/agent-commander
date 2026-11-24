---
type: Design Pattern
title: Content Filter
description: "A content filter projects selected information into a smaller message for a particular consumer."
family: EIP
category: Message Transformation
tags: [eip, message-transformation, field-projection]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: eip
    resource: https://www.enterpriseintegrationpatterns.com/patterns/messaging/ContentFilter.html
    title: Content Filter
    author: 'human:hohpe-woolf'
---

# Content Filter

## When to use

A friend has permission to view job progress but should see neither the prompt nor local filesystem paths.

## Abstract implementation

Define a purpose-specific output schema, allowlist the source fields needed for that view, and construct a new message. Distinguish an absent field from a value removed by policy when consumers need that information.

`{id, status, path, contents} → {id, status}` constructs the progress view.

## Concrete implementation

On the receiving host, project a full worker event to `Progress{JobID, State, UpdatedAt}` for an authorized observer. Construct the Go response from those fields explicitly and seal it for that observer. Tests should add an unexpected source field and verify it stays out of the projection.

## Trade-offs

A smaller schema limits disclosure and bandwidth. It also creates another contract to version. Once filtered out, a field requires a separately authorized fetch if the consumer later needs it.

## Commonly Used With

- [Message Filter](./message-filter.md) — Select eligible events before reducing their fields.
- [Content Enricher](./content-enricher.md) — Attach necessary contextual facts before projecting the consumer-specific view.
