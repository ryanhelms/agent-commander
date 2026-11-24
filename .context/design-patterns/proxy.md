---
type: Design Pattern
title: Proxy
description: "A proxy represents another object and controls how clients reach it through the same interface."
family: GoF
category: Structural
tags:
  - interfaces
  - remote-access
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: gof
    resource: https://www.informit.com/store/design-patterns-elements-of-reusable-object-oriented-9780201633610
    title: "Design Patterns: Elements of Reusable Object-Oriented Software"
    author: "human:gamma-helm-johnson-vlissides"
---

# Proxy

## When to use

Choose a proxy when the client needs an operation on a particular object and access requires a network hop, lazy lookup or an authorization check. Preserve the target's identity through any indirection.

## Abstract implementation

Both proxy and real subject implement the subject interface. The proxy holds a reference or stable locator, applies access behavior and forwards the request. A remote proxy also defines what the client observes when the underlying object's state is unknown.

For example, `RemotePrinter(printerID).status()` forwards the status query to the selected printer and returns its response through the same interface as a local printer.

## Concrete implementation

A proposed remote worker proxy could address a worker through its enrolled owner host. Input requests would carry the observed lease generation. The host would compare that generation against the live binding immediately before delivery.

```text
worker = RemoteWorker(hostID, workerID, relay)
request = InputIntent(id = newID(), generation = heldLease.generation, text = input)
result = worker.send(request)
if result is Unknown: showPendingReconciliation(request.id)
```

## Trade-offs

A remote call can fail after the action occurred. Modeling a timeout as a definite rejection invites duplicate input. Provide a receipt lookup, and limit automatic retries to operations that can deduplicate them.

## Commonly Used With

- [Adapter](adapter.md) can translate the real subject's provider-specific calls behind the proxy.
- [Command](command.md) gives a forwarded action a stable identity that survives a dropped response.
- [Fencing Token](fencing-token.md) lets the host reject input from a proxy holding an obsolete lease generation.
