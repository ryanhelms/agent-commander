---
type: Design Pattern
title: Command
description: "A command represents an intended action as data so acceptance and execution can happen at different times."
family: GoF
category: Behavioral
tags:
  - operations
  - replay
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: gof
    resource: https://www.informit.com/store/design-patterns-elements-of-reusable-object-oriented-9780201633610
    title: "Design Patterns: Elements of Reusable Object-Oriented Software"
    author: "human:gamma-helm-johnson-vlissides"
---

# Command

## When to use

Use a command when callers need a queueable, auditable operation with a named target and a result they can recover later. A frequently retried request to answer a worker's question is one such operation.

## Abstract implementation

The invoker submits a command. The command identifies the receiver, parameters and preconditions. A handler dispatches it to the receiver. Execution tracking, idempotency and compensation need explicit contracts for each action.

For example, `queue.submit(RenameDocument(id, newTitle))` binds the target and arguments now, and a worker invokes the rename after dequeue.

## Concrete implementation

A proposed relay could accept an answer addressed to one question in one worker. It would bind the actor at the authenticated endpoint, persist the command, and record delivery under its original command ID. A repeated ID with different content would be rejected.

```text
command = Answer(id, actorFromConnection, workerID, questionID, text)
record = inbox.insertOrFind(command.id, digest(command))
if record.digest != digest(command): return Conflict
return record.operationID
```

## Trade-offs

A durable command gives a retry something stable to refer to. Once an external provider has accepted an answer, undo may be impossible. Track uncertain delivery and reconcile with the provider before attempting it again.

## Commonly Used With

- [Chain of Responsibility](chain-of-responsibility.md) can assign a submitted command to the first eligible handler.
- [Memento](memento.md) can preserve pre-operation state for commands whose local effects are reversible.
- [Idempotent Receiver](idempotent-receiver.md) can recover the original outcome when the same command arrives again.
