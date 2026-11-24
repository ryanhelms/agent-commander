---
type: Design Pattern
title: Envelope Wrapper
description: "An envelope adds transport metadata around an intact application message."
family: EIP
category: Message Transformation
tags: [eip, message-transformation, message-encapsulation]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: eip
    resource: https://www.enterpriseintegrationpatterns.com/patterns/messaging/EnvelopeWrapper.html
    title: Envelope Wrapper
    author: 'human:hohpe-woolf'
---

# Envelope Wrapper

## When to use

An endpoint already understands a job request, but the relay also needs a routable destination and a supported wire version.

## Abstract implementation

Wrap the serialized application message in a versioned outer structure. The transport reads only its required headers. The destination verifies the envelope, extracts the original bytes, and passes them to the application decoder.

`wrap(destination, version, body) → envelope`, then `unwrap(verifiedEnvelope) → body`.

## Concrete implementation

A sending device can use its established encryption session to seal the application request, binding the protocol version and recipient device ID as authenticated metadata. Encode those outer fields alongside the ciphertext. At the receiver, verify the binding before decoding the request or applying its grant. The relay uses only the outer destination.

## Trade-offs

Even encrypted messages reveal exposed identifiers, sizes, and timing. Specify which headers intermediaries may mutate and cap envelope lengths before allocating buffers.

## Commonly Used With

- [Content-Based Router](./content-based-router.md) — Route on the permitted outer header without reading the application body.
- [Canonical Data Model](./canonical-data-model.md) — Give the extracted message stable semantics across transport versions.
