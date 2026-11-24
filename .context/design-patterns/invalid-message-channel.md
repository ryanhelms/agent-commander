---
type: Design Pattern
title: "Invalid Message Channel"
description: "A receiver moves messages that fail its acceptance rules to a dedicated inspection channel."
family: EIP
category: "Messaging Channels"
tags: ["eip","validation","quarantine"]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: eip
    resource: https://www.enterpriseintegrationpatterns.com/patterns/messaging/InvalidMessageChannel.html
    title: "Invalid Message Channel"
    author: 'human:hohpe-woolf'
---

# Invalid Message Channel

## When to use

A consumer can identify a permanent problem with the received representation and needs to keep that input from repeatedly blocking valid work.

## Abstract implementation

Define validation failures the receiver can identify, such as an unknown required field or an impossible state transition. Record the original message or an authorized reference together with the failing rule and the receiver version.

`decode(input) → missing required field → quarantine(input, "missing-run-id") → ack(original)`

## Concrete implementation

A recipient opening an encrypted task could reject a signed body with an invalid schema version. It would persist a private quarantine entry keyed by message ID plus a reason code before acknowledging the source delivery. A support view could show the code without exposing the body.

## Trade-offs

Contract changes can send legitimate traffic to quarantine. Bound storage and retention, restrict readers and make any operator replay pass current authorization and validation again.

## Commonly Used With

- An explicit schema identifier lets the receiver report which representation it could not accept. [Format Indicator](format-indicator.md)
- Delivery exhaustion has a different cause and can be tracked separately for diagnosis. [Dead Letter Channel](dead-letter-channel.md)
