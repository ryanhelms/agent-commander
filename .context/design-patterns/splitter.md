---
type: Design Pattern
title: Splitter
description: "A splitter turns independently processable elements of one input into separate messages."
family: EIP
category: Message Routing
tags: [eip, message-routing, decomposition]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: eip
    resource: https://www.enterpriseintegrationpatterns.com/patterns/messaging/Sequencer.html
    title: Splitter
    author: 'human:hohpe-woolf'
---

# Splitter

## When to use

A review contains several file groups that can be inspected independently.

## Abstract implementation

Identify element boundaries, preserve the parent ID, and assign a stable identity to every child. Include a count or end marker when another component must reassemble the results.

`split(batch42, [x, y]) → [(batch42, 1, x), (batch42, 2, y)]`.

## Concrete implementation

At the endpoint holding the review, validate and parse the manifest. Derive each child ID from `(reviewID, manifestVersion, position)`. Persist the child set before dispatch and include only the file references authorized for each assignment. Encrypt remote assignments for their respective receivers.

## Trade-offs

One large element can dominate completion time. Define what an empty manifest returns and whether one failed child cancels its siblings.

## Commonly Used With

- [Aggregator](./aggregator.md) — Reassemble findings using the parent ID and expected child set.
- [Message Sequence](./message-sequence.md) — Preserve original positions and completeness information where order matters.
