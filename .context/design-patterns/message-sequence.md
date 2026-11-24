---
type: Design Pattern
title: "Message Sequence"
description: "A sender represents a large logical message as identified parts that a receiver can reassemble."
family: EIP
category: "Message Construction"
tags: ["eip","chunking","assembly"]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: eip
    resource: https://www.enterpriseintegrationpatterns.com/patterns/messaging/MessageSequence.html
    title: "Message Sequence"
    author: 'human:hohpe-woolf'
---

# Message Sequence

## When to use

A payload exceeds the transport limit, or a producer must start sending a bounded stream before it can materialize the whole object.

## Abstract implementation

Tag each part with a sequence ID and a position. Supply a total count, total length or explicit end condition. The receiver groups parts by sequence, detects holes and completes assembly only when the required positions are present.

`part(S, 2/3), part(S, 1/3), part(S, 3/3) → assemble(S, [1, 2, 3])`

## Concrete implementation

An endpoint could split an encrypted export into 128 KiB parts and send an authenticated manifest with the object digest, size and part count. The recipient stages parts under `(sender, sequenceID, index)`, bounds the index and size, then checks completeness and digest before exposing the object.

## Trade-offs

Missing parts consume storage and prevent completion. Put quotas and cleanup deadlines on incomplete assemblies. Repeated indexes with different content need an explicit rejection policy.

## Commonly Used With

- The sequence ID groups parts of one transfer when several transfers overlap. [Correlation Identifier](correlation-identifier.md)
- An assembly deadline bounds the lifetime of abandoned transfers. [Message Expiration](message-expiration.md)
