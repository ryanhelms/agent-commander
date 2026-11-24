---
type: Design Pattern
title: "Message Channel"
description: "A named communication path connects senders to receivers under a shared delivery contract."
family: EIP
category: "Messaging Systems"
tags: ["eip","transport","routing"]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: eip
    resource: https://www.enterpriseintegrationpatterns.com/patterns/messaging/MessageChannel.html
    title: "Message Channel"
    author: 'human:hohpe-woolf'
---

# Message Channel

## When to use

Applications need a stable destination while workers come and go or move between hosts.

## Abstract implementation

Define the channel name, accepted message types, authorized senders and delivery behavior. Senders address that name. The transport binds currently eligible receivers or retains work if the channel promises persistence.

`send(channel="ready-jobs", job42) → receive(channel="ready-jobs")`

## Concrete implementation

A service could publish completion notices on `run.<runID>.completed`. The server grants the run’s observers subscribe permission on that subject. A returning observer first reads current run state if the channel carries live notices only.

## Trade-offs

A name introduces a versioned interface, even when the wire payload stays stable. Overly broad subjects can expose other tenants’ traffic, while excessive partitioning adds routing and subscription overhead.

## Commonly Used With

- Independent observers each need a copy of a completion notice. [Publish-Subscribe Channel](publish-subscribe-channel.md)
- A work channel instead gives one eligible consumer responsibility for a delivery. [Point-to-Point Channel](point-to-point-channel.md)
