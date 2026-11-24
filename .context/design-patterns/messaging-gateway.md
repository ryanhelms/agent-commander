---
type: Design Pattern
title: "Messaging Gateway"
description: "Hide broker operations behind a domain operation with explicit delivery semantics."
family: EIP
category: Messaging Endpoints
tags: ["integration","encapsulation","api"]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: eip
    resource: https://www.enterpriseintegrationpatterns.com/patterns/messaging/MessagingGateway.html
    title: "Messaging Gateway"
    author: "human:hohpe-woolf"
---

# Messaging Gateway

## When to use

Use when business callers keep reconstructing subjects, encoding envelopes or interpreting broker acknowledgements. A single internal publisher can start as a function.

## Abstract implementation

Expose an operation such as `SubmitOrder(orderID, order)`. The gateway translates the call, publishes it and returns a receipt describing the stage reached. Callers decide how to act on that receipt without knowing the wire format.

Example — `orders.submit(order) → acceptance receipt → later completion query`

## Concrete implementation

In the proposed Go relay, `SubmitGroupRequest(ctx, principal, request)` validates the caller and records a parent operation, frozen recipients and pending deliveries in one transaction. The tray receives an accepted operation ID. It can request recipient receipts separately while relay workers publish committed deliveries.

## Trade-offs

A convenient synchronous signature can suggest that work finished when the broker merely accepted a message. Name acceptance and completion separately and retain cancellation and timeout information.

## Commonly Used With

- [Messaging Mapper](messaging-mapper.md) converts the domain records at the boundary.
- [Request-Reply](request-reply.md) correlates a later operation result with the submitting caller.
