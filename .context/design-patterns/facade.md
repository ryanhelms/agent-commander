---
type: Design Pattern
title: Facade
description: "A facade gives clients a small entry point for an operation that spans several subsystem interfaces."
family: GoF
category: Structural
tags:
  - interfaces
  - api
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: gof
    resource: https://www.informit.com/store/design-patterns-elements-of-reusable-object-oriented-9780201633610
    title: "Design Patterns: Elements of Reusable Object-Oriented Software"
    author: "human:gamma-helm-johnson-vlissides"
---

# Facade

## When to use

Use a facade when callers repeatedly need the same coordination steps and should receive the same outcome. Starting a shared run might otherwise force the CLI, MCP tool and native app to each reproduce policy checks, enrollment lookup and dispatch.

## Abstract implementation

Expose operations in the client's vocabulary. The facade translates one operation into calls on the relevant subsystems and returns a result meaningful to that client. Those subsystems can still have their own lifecycles, transactions and specialized operations.

For example, `checkout.placeOrder(cartID)` can validate the cart, reserve stock and return an order receipt. The caller supplies the cart once.

## Concrete implementation

A proposed Go relay facade could accept a run request from the CLI or MCP and return an operation ID. It would resolve the authenticated actor, ask the grant service to authorize the request, and ask a job service to persist a deduplicated submission with its outgoing event.

```text
submitSharedRun(ctx, request):
    actor = sessions.requireActor(ctx)
    grant = grants.authorize(actor, request.worker, "invoke")
    return jobs.acceptOnce(actor.id, request.id, grant.id, request)
```

## Trade-offs

A single entry point reduces drift among clients. It does not by itself provide atomicity across its collaborators. Give one service responsibility for committing acceptance, and recheck the grant before queued work executes.

## Commonly Used With

- [Adapter](adapter.md) maps individual provider operations behind the facade.
- [Command](command.md) can represent a submission that the facade accepts and the job service executes later.
- [Messaging Gateway](messaging-gateway.md) can encapsulate how the facade submits that command to a broker.
