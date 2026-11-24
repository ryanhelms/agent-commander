---
type: Design Pattern
title: "Message Bus"
description: "Applications integrate through shared messaging infrastructure, common contracts and agreed operation names."
family: EIP
category: "Messaging Channels"
tags: ["eip","integration","contracts"]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: eip
    resource: https://www.enterpriseintegrationpatterns.com/patterns/messaging/MessageBus.html
    title: "Message Bus"
    author: 'human:hohpe-woolf'
---

# Message Bus

## When to use

Several applications need predictable ways to exchange commands and events without individually negotiating every pairwise interface.

## Abstract implementation

Choose common representations for shared concepts and define how participants find the operations they use. Connect each application through an adapter that translates between its own model and the bus contract.

`buildAdapter → bus.publish(RunClosedV1) → billingAdapter and reportingAdapter` share the same closure contract.

## Concrete implementation

A build coordinator, usage collector and notification service could share `RunRef` and `RunClosedV1` contracts. The coordinator publishes closure under a tenant-scoped address. Each enrolled service maps that contract to its own records and subscribes only to permitted addresses.

## Trade-offs

A common model reduces repeated pairwise translation, but every breaking change affects multiple owners. Assign ownership to each contract and budget for compatibility windows. Participation in the bus still requires explicit access rules.

## Commonly Used With

- Each application connects its local interface to the shared messaging infrastructure. [Channel Adapter](channel-adapter.md)
- Type-specific addresses make published bus contracts discoverable and independently versionable. [Datatype Channel](datatype-channel.md)
