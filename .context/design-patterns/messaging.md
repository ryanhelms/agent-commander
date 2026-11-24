---
type: Design Pattern
title: "Messaging"
description: "Applications exchange discrete messages through a transport so sending and processing can happen separately."
family: EIP
category: "Integration Styles"
tags: ["eip","asynchronous","integration"]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: eip
    resource: https://www.enterpriseintegrationpatterns.com/patterns/messaging/Messaging.html
    title: "Messaging"
    author: 'human:hohpe-woolf'
---

# Messaging

## When to use

The worker might be offline when an assignment is issued, or the sender should continue before that work finishes.

## Abstract implementation

The sender encodes the intent, addresses it to a channel and hands it to the transport. A receiver independently consumes and processes it. Choose persistence, acknowledgments and retention according to the cost of loss.

`producer sends Task(42) → broker buffers it → worker receives Task(42) when available`

## Concrete implementation

A dispatcher could enqueue a sealed assignment for a named executor and return an operation ID after durable acceptance. The executor opens the envelope, checks its grant, processes the assignment and records an outcome under that ID.

## Trade-offs

Separating send and execution introduces a period when the outcome is unknown. Transport acceptance, receiver processing and business completion need distinct observable states. An ephemeral transport alone cannot deliver to an offline worker.

## Commonly Used With

- The envelope gives the transport a boundary for one unit of work. [Message](message.md)
- The channel supplies the route and delivery policy for the exchange. [Message Channel](message-channel.md)
