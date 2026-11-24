---
type: Design Pattern
title: "Dead Letter Channel"
description: "The messaging system diverts messages it can no longer deliver under its routing and retry policies."
family: EIP
category: "Messaging Channels"
tags: ["eip","delivery","recovery"]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: eip
    resource: https://www.enterpriseintegrationpatterns.com/patterns/messaging/DeadLetterChannel.html
    title: "Dead Letter Channel"
    author: 'human:hohpe-woolf'
---

# Dead Letter Channel

## When to use

A message can exhaust its delivery attempts, lose its destination or otherwise become undeliverable, and operators need a recovery record.

## Abstract implementation

Define which delivery failures are terminal. On reaching one, transfer the original envelope or a retrievable reference with its delivery history to a designated channel. Remove the source item only after the transfer succeeds.

`delivery attempts exhausted → store(deadLetters, envelope, lastError) → settle(original)`

## Concrete implementation

A relay configured for five attempts could store a sealed envelope, destination and failure class under its stable message ID in a restricted dead-letter store. Completing that write before acknowledging the original makes a crash recoverable. A repeated transfer upserts the same entry.

## Trade-offs

Brokers differ in how they surface delivery exhaustion. Retention and access controls govern whether recovery remains possible. Redriving a stale command requires checking its expiry and whether it already took effect.

## Commonly Used With

- An expired item can be distinguished from one that exhausted delivery attempts. [Message Expiration](message-expiration.md)
- Receiver-declared validation failures carry different evidence from transport failures. [Invalid Message Channel](invalid-message-channel.md)
