---
type: Design Pattern
title: Resequencer
description: "A resequencer buffers related messages and emits them in the required order."
family: EIP
category: Message Routing
tags: [eip, message-routing, event-ordering]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: eip
    resource: https://www.enterpriseintegrationpatterns.com/patterns/messaging/Resequencer.html
    title: Resequencer
    author: 'human:hohpe-woolf'
---

# Resequencer

## When to use

Transcript frames can be replayed over a replacement connection while an earlier path is still draining. The console needs a coherent sequence for each worker.

## Abstract implementation

Track the next expected position per stream epoch. Emit contiguous entries, buffer later ones, and discard positions already emitted. Bound the wait for a missing position.

With `next = 7`, arrivals `[8, 7, 9]` produce emissions `[], [7, 8], [9]`.

## Concrete implementation

Inside the authorized client, key buffers by `(workerID, streamEpoch)` after decryption. If frame 19 arrives before 18, hold 19 and request the missing range. Append both when 18 arrives. If retention has expired, fetch a fresh checkpoint or show the gap and resume at an explicit cursor.

## Trade-offs

A missing message can block every later one. Cap both bytes and entries per worker. Independent worker streams should continue while another waits.

## Commonly Used With

- [Message Sequence](./message-sequence.md) — Provide the stream identity and position the buffer needs.
- [Message Store](./message-store.md) — Keep an authorized replay window for repairing gaps.
