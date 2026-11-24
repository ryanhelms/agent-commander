---
type: Design Pattern
title: "Point-to-Point Channel"
description: "A queue delivers each message to one logical consumer among the workers attached to it."
family: EIP
category: "Messaging Channels"
tags: ["eip","queue","work-distribution"]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: eip
    resource: https://www.enterpriseintegrationpatterns.com/patterns/messaging/PointToPointChannel.html
    title: "Point-to-Point Channel"
    author: 'human:hohpe-woolf'
---

# Point-to-Point Channel

## When to use

Several interchangeable workers can perform a job, and one completed execution satisfies the request.

## Abstract implementation

Address work to a queue. The broker assigns each available message to one worker, tracks the outstanding delivery and releases it for another attempt when the acknowledgement deadline passes.

`enqueue(job42) → lease(job42, workerA) → ack(job42)` leaves worker B free to take the next job.

## Concrete implementation

A pool of Go thumbnail workers could share a queue of artifact IDs. The winner writes its result under a stable job ID and acknowledges after committing it. A worker picking up a retry first checks whether that job already produced an output.

## Trade-offs

An expired lease can leave two workers briefly processing the same job. Parallel consumption can also change completion order. Make the result write safe to repeat and choose a lease that covers ordinary processing time.

## Commonly Used With

- The channel contract defines which workers can read and acknowledge work. [Message Channel](message-channel.md)
- Each queued job can name the action one worker should carry out. [Command Message](command-message.md)
