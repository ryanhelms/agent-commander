---
type: Design Pattern
title: "Remote Procedure Invocation"
description: "A caller integrates with another application through a named operation and its request and response contract."
family: EIP
category: "Integration Styles"
tags: ["eip","rpc","service-boundary"]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: eip
    resource: https://www.enterpriseintegrationpatterns.com/patterns/messaging/EncapsulatedSynchronousIntegration.html
    title: "Remote Procedure Invocation"
    author: 'human:hohpe-woolf'
---

# Remote Procedure Invocation

## When to use

The remote application owns the data or behavior and the caller needs a prompt answer to proceed.

## Abstract implementation

A client proxy serializes arguments, addresses the service and decodes either a result or a remote error. The service validates the caller, maps the operation to a handler and returns its response.

`client calls ReserveSlot(3) → service checks capacity → client receives ReservationID(42)`

## Concrete implementation

In Go, a cockpit can issue an authenticated GET for an operation’s status with a request context and a short deadline. The handler checks the caller’s scope and returns the status for the supplied operation ID. A mutating retry would additionally need an idempotency key.

## Trade-offs

Network latency and outages become part of the caller’s control flow. A timeout after sending a mutation leaves its outcome uncertain. Define a lookup or retry contract before a caller repeats it.

## Commonly Used With

- A message transport can carry the call and its response as separate messages. [Request-Reply](request-reply.md)
- A client sharing a connection needs to match each response to the outstanding call. [Correlation Identifier](correlation-identifier.md)
