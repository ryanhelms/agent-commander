---
type: Design Pattern
title: Claim Check
description: "A claim check replaces a bulky payload with a reference that an authorized consumer can redeem."
family: EIP
category: Message Transformation
tags: [eip, message-transformation, attachment-transfer]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: eip
    resource: https://www.enterpriseintegrationpatterns.com/patterns/messaging/StoreInLibrary.html
    title: Claim Check
    author: 'human:hohpe-woolf'
---

# Claim Check

## When to use

A worker needs a large artifact that would exceed frame limits or force unrelated gateway components to buffer its contents.

## Abstract implementation

Place the payload in a store, issue a reference, and continue routing the small message. Define ownership, integrity verification, expiration, and cleanup of unclaimed content.

`store(bytes) → ref`, then `send(ref) → authorize(ref) → fetch(ref) → verify(bytes)`.

## Concrete implementation

A sender could store an encrypted artifact and include an opaque object ID, digest, length, and expiration inside the recipient's encrypted job request. The recipient presents its identity to redeem the object, verifies size and digest, and decrypts locally. Delay garbage collection until the retry window ends or an agreed acknowledgement arrives.

## Trade-offs

This reduces pressure on message channels but creates a second availability dependency. A bearer-style reference can leak access, and deleting content too soon can break redelivery.

## Commonly Used With

- [Message Expiration](./message-expiration.md) — Bound the lifetime of a redeemable reference.
- [Envelope Wrapper](./envelope-wrapper.md) — Protect the reference and its integrity metadata on the wire.
