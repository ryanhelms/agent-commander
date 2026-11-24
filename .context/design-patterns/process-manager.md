---
type: Design Pattern
title: Process Manager
description: "A process manager stores workflow state and selects the next action when events arrive."
family: EIP
category: Message Routing
tags: [eip, message-routing, workflow-coordination]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: eip
    resource: https://www.enterpriseintegrationpatterns.com/patterns/messaging/ProcessManager.html
    title: Process Manager
    author: 'human:hohpe-woolf'
---

# Process Manager

## When to use

A borrowing request may require an owner decision, a reservation, a worker result, or release of a reservation after cancellation.

## Abstract implementation

Represent the workflow as durable states and guarded transitions. For each correlated event, record both the new state and the command to issue. Accept repeated events according to the current state.

`awaitingApproval + Approved → reserving / send Reserve`. `reserving + Denied → finished / notify requester`.

## Concrete implementation

A requesting host starts a job in `awaitingApproval`. Approval permits a `Reserve` request with a stable operation ID. Only the receiver's reservation receipt permits `Start`. After a timeout on `Start`, reconcile its receipt before retrying. Cancellation in the reserved state issues `Release` and awaits the host's outcome.

## Trade-offs

Explicit state aids recovery, but the coordinator becomes a dependency. Recording success before an external action's outcome is known can strand capacity or duplicate a job.

## Commonly Used With

- [Correlation Identifier](./correlation-identifier.md) — Route owner decisions and job receipts to the correct workflow.
- [Routing Slip](./routing-slip.md) — Delegate a fixed sequence of local stages after choosing it.
