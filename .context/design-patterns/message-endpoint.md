---
type: Design Pattern
title: "Message Endpoint"
description: "An application uses a transport-facing component to send messages to a channel or receive them from one."
family: EIP
category: "Messaging Systems"
tags: ["eip","boundary","consumer"]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: eip
    resource: https://www.enterpriseintegrationpatterns.com/patterns/messaging/MessageEndpoint.html
    title: "Message Endpoint"
    author: 'human:hohpe-woolf'
---

# Message Endpoint

## When to use

A domain handler should receive validated inputs while a dedicated component manages transport subscriptions, acknowledgments or serialization.

## Abstract implementation

Bind a sender or receiver to the channel. At a receiving endpoint, decode and validate the envelope, invoke the application operation and map its disposition to the transport’s acknowledgment or retry behavior.

`delivery → endpoint.decode → handler.commit → endpoint.ack(delivery)`

## Concrete implementation

A Go consumer for an inbox could authenticate and decrypt the assignment, call `AcceptAssignment` with the operation ID, and acknowledge only after the handler’s durable acceptance. A repeat delivery reuses the stored decision for that ID.

## Trade-offs

The endpoint is where transport lifecycle meets application outcome. Acknowledging too early can lose work. Acknowledging too late can trigger duplicate processing when the supervisor restarts.

## Commonly Used With

- A shared wire contract lets the endpoint validate before dispatch. [Message](message.md)
- Persistent delivery can carry a message across endpoint downtime until an acknowledgment arrives. [Guaranteed Delivery](guaranteed-delivery.md)
