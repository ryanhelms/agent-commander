---
type: Design Pattern
title: "Command Message"
description: "A message asks its recipient to perform a named operation with supplied arguments."
family: EIP
category: "Message Construction"
tags: ["eip","intent","commands"]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: eip
    resource: https://www.enterpriseintegrationpatterns.com/patterns/messaging/CommandMessage.html
    title: "Command Message"
    author: 'human:hohpe-woolf'
---

# Command Message

## When to use

A sender needs some work to happen, and it should be possible to enqueue, authorize or execute the request independently of sending it.

## Abstract implementation

Represent the operation and its inputs explicitly. Give it a stable identity and route it to an endpoint responsible for deciding whether the action is allowed and valid in the current state.

`CancelRun{commandID: 85, runID: 42, expectedGeneration: 3} → authorized run handler`

## Concrete implementation

An authorized owner could send a sealed `CancelRun` carrying a command ID, run ID and expected generation. The recipient verifies the sender, checks the generation, then records the command ID and cancellation in one transaction. A retry can return the recorded outcome.

## Trade-offs

Dispatch acceptance confirms only that the request entered the system. The command may later be rejected or arrive after the run has finished. State preconditions and replay-safe handling make that distinction observable.

## Commonly Used With

- One logical handler can own execution of each command. [Point-to-Point Channel](point-to-point-channel.md)
- A caller that needs the decision can request a separately delivered outcome. [Request-Reply](request-reply.md)
