---
type: Design Pattern
title: "Service Activator"
description: "Translate an incoming message into an invocation of an application service and publish its outcome."
family: EIP
category: Messaging Endpoints
tags: ["invocation","application-service","adapter"]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: eip
    resource: https://www.enterpriseintegrationpatterns.com/patterns/messaging/MessagingAdapter.html
    title: "Service Activator"
    author: "human:hohpe-woolf"
---

# Service Activator

## When to use

Use when queue-driven and direct callers should exercise the same business operation and authorization logic.

## Abstract implementation

A listener decodes a request, reconstructs the authenticated caller context, invokes `ReserveInventory` and maps success or rejection to a response carrying the request ID.

Example — `request envelope → decode caller and arguments → service.reserve(...) → correlated reply`

## Concrete implementation

At a recipient Commander, a Go activator verifies and decrypts the child envelope, resolves its local worker, and calls the same scoped run service used by a direct request. That service rechecks the owner’s grant, payer cap and operation receipt before starting a worker. The activator returns a correlated outcome.

## Trade-offs

Invocation by message introduces expiry, retries and uncertain completion. Pass the deadline and identity into the service and treat an acknowledgement and a completed model turn as distinct outcomes.

## Commonly Used With

- [Messaging Mapper](messaging-mapper.md) converts the command envelope to the service’s input type.
- [Idempotent Receiver](idempotent-receiver.md) keeps duplicate activations from starting another paid operation.
