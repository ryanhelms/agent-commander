---
type: Design Pattern
title: Wire Tap
description: "A wire tap copies traffic to a second destination for observation while the original message continues."
family: EIP
category: System Management
tags: [eip, system-management, observability]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: eip
    resource: https://www.enterpriseintegrationpatterns.com/patterns/messaging/WireTap.html
    title: Wire Tap
    author: 'human:hohpe-woolf'
---

# Wire Tap

## When to use

Operators need to measure delivery behavior without introducing another consumer that competes for the worker's messages.

## Abstract implementation

Copy each passing message onto an observation branch while forwarding the original along its normal path. Place filters on the branch and specify what happens when the observer is slower than the main path.

`forward(original)` continues the main delivery and `offer(copy, observer)` attempts an independent diagnostic delivery.

## Concrete implementation

At an edge, tap each permitted outer delivery event and immediately project it to route class, frame size, outcome, and latency bucket. Send that projection to a bounded diagnostic channel. When it is full, increment a dropped-sample counter. Keep bearer headers, plaintext transcripts, and ciphertext bodies out of diagnostic storage.

## Trade-offs

Asynchronous sampling can lose evidence during overload. A lossless tap couples throughput to the observer and creates a second destination whose access and retention need explicit limits.

## Commonly Used With

- [Content Filter](./content-filter.md) — Reduce the copied event to the permitted diagnostic fields.
- [Message Store](./message-store.md) — Retain selected samples for later analysis with an explicit retention period.
