---
type: Design Pattern
title: "Message"
description: "A transport carries one bounded unit containing a payload and the metadata needed to deliver and interpret it."
family: EIP
category: "Messaging Systems"
tags: ["eip","envelope","wire-contract"]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: eip
    resource: https://www.enterpriseintegrationpatterns.com/patterns/messaging/Message.html
    title: "Message"
    author: 'human:hohpe-woolf'
---

# Message

## When to use

A sender needs a receiver to recognize where one command, event or document ends, including during buffering and retry.

## Abstract implementation

Define a header and body contract. Put routing or dispatch information in the header and the application content in the body. Validate size and encoding before handing a decoded value to the application.

`Envelope(header={id: 42, to: "worker-7"}, body=encodedTask)`

## Concrete implementation

An assignment envelope could include `message_id`, `destination`, `format` and a sealed body. The sending endpoint authenticates routing fields as associated data. The relay can address and limit the envelope, while the destination opens and validates the assignment.

## Trade-offs

Splitting one logical operation across several envelopes introduces assembly and ordering work. Visible headers reveal metadata, so identifiers and lengths deserve a disclosure decision alongside payload encryption.

## Commonly Used With

- The receiver can select a decoder from an explicit format field. [Format Indicator](format-indicator.md)
- The sender hands the complete envelope to a channel with compatible delivery semantics. [Message Channel](message-channel.md)
