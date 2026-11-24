---
type: Design Pattern
title: "Polling Consumer"
description: "Let a receiver request messages when it has capacity to process them."
family: EIP
category: Messaging Endpoints
tags: ["backpressure","pull","capacity"]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: eip
    resource: https://www.enterpriseintegrationpatterns.com/patterns/messaging/PollingConsumer.html
    title: "Polling Consumer"
    author: "human:hohpe-woolf"
---

# Polling Consumer

## When to use

Use when worker capacity varies or expensive work must wait for a local slot to become available.

## Abstract implementation

A renderer with three free slots asks its queue for at most three records with a bounded wait. It asks again after a slot returns and can cancel the outstanding poll on shutdown.

Example — `free = available_slots(); batch = pull(at_most=free, deadline=t)`

## Concrete implementation

A Go dispatcher keeps a bounded pool of forwarding slots. It reserves available slots before pulling a JetStream batch, releases excess slots on a short fetch, and only acknowledges each durable record after the corresponding outcome is recorded. A long poll wakes for work or a deadline.

## Trade-offs

Tight empty polls waste CPU and network. Oversized batches start acknowledgement timers on work that cannot run yet. Tune fetch size and wait duration against real capacity and redelivery behavior.

## Commonly Used With

- [Competing Consumers](competing-consumers.md) lets other dispatchers pull from the same work queue.
- [Message Expiration](message-expiration.md) allows the receiver to close a stale item before work starts.
