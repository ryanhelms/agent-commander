---
type: Design Pattern
title: Test Message
description: "A test message traverses a real processing path and produces a known outcome that an observer can verify."
family: EIP
category: System Management
tags: [eip, system-management, functional-probing]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: eip
    resource: https://www.enterpriseintegrationpatterns.com/patterns/messaging/TestMessage.html
    title: Test Message
    author: 'human:hohpe-woolf'
---

# Test Message

## When to use

A relay connection answers a health check, but you also need evidence that addressing, decoding, and the reply path work together.

## Abstract implementation

Send synthetic input with a recognizable identity and expected response through the target components. Isolate its side effects and compare the actual outcome with the expectation under a deadline.

`send(probeID, fixture) → observe(replyID, result) → assert(replyID = probeID and result = expected)`.

## Concrete implementation

Enroll a synthetic Commander host and issue a challenge to its QA endpoint with a unique ID and fixed byte sequence. Resolve it through the normal gateway and tunnel, validate the expected digest at the endpoint, and verify that the authenticated response echoes the ID and result. A mismatch or timeout fails the probe. No user prompts, credentials, or model credits are needed.

## Trade-offs

A probe tests only the path and semantics it exercises. A successful digest round trip proves more than a TCP handshake, but says nothing about whether a real model can execute a job.

## Commonly Used With

- [Control Bus](./control-bus.md) — Schedule probes and collect their results through the management path.
- [Correlation Identifier](./correlation-identifier.md) — Distinguish a fresh response from one belonging to an earlier probe.
