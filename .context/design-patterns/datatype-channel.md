---
type: Design Pattern
title: "Datatype Channel"
description: "Each channel carries one agreed data type so the channel identifies the expected message representation."
family: EIP
category: "Messaging Channels"
tags: ["eip","schema","dispatch"]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: eip
    resource: https://www.enterpriseintegrationpatterns.com/patterns/messaging/DatatypeChannel.html
    title: "Datatype Channel"
    author: 'human:hohpe-woolf'
---

# Datatype Channel

## When to use

Consumers subscribe by data type, and the producer and consumer can agree on a stable set of types.

## Abstract implementation

Allocate a channel per wire contract. Senders publish only compatible values there. A consumer opens the appropriate channel and uses its registered decoder, while still checking incoming bytes against that contract.

`send(usageHours, UsageHour{...})` and `send(rosters, RosterSnapshot{...})` select different typed channels.

## Concrete implementation

A Go receiver could bind `usage.hour.v1` to `UsageHourV1` and `roster.snapshot.v1` to `RosterSnapshotV1`. Only the usage producer receives publish permission for the usage subject. An incompatible usage schema gets a new subject and an explicit migration period.

## Trade-offs

Many fine-grained types multiply channels, bindings and access rules. A descriptive channel name can disclose the kind of encrypted traffic, and the chosen channel alone cannot prove a sender encoded a valid value.

## Commonly Used With

- A distinct address gives each datatype its own subscription and permission boundary. [Message Channel](message-channel.md)
- A value that fails the advertised schema can be isolated for inspection. [Invalid Message Channel](invalid-message-channel.md)
