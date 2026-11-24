---
type: Design Pattern
title: Template Method
description: "A template method fixes the sequence of an operation while granting implementations control over selected steps."
family: GoF
category: Behavioral
tags:
  - workflow
  - invariants
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: gof
    resource: https://www.informit.com/store/design-patterns-elements-of-reusable-object-oriented-9780201633610
    title: "Design Patterns: Elements of Reusable Object-Oriented Software"
    author: "human:gamma-helm-johnson-vlissides"
---

# Template Method

## When to use

Choose this when several variants must carry out the same sequence and a small number of steps vary. Good candidates include host enrollment probes with shared validation and recording but different transport mechanisms.

## Abstract implementation

The template owns ordering, required checks and error handling, and invokes primitive operations or hooks at documented points. In Go, an ordinary function can accept an implementation of the hooks. Give hooks only the data they need for their step.

For example, `report.generate()` can always load, validate and publish in that order while calling `format(rows)` on a CSV or HTML implementation between validation and publication.

## Concrete implementation

An envisioned relay enrollment flow could open a candidate transport, issue a fresh challenge, verify a signature against an independently enrolled public key, and only then record the connection. TCP and local socket variants would implement the transport steps.

```text
enroll(candidate, connector):
    link = connector.open(candidate.address)
    defer link.close()
    nonce = secureRandom()
    proof = link.challenge(nonce)
    verify(candidate.enrolledKey, nonce, proof)
    return hosts.recordVerified(candidate.id, proof)
```

## Trade-offs

The shared sequence keeps required checks in one place. An expanding set of optional hooks makes ordering difficult to understand. If variants need different sequences, prefer separate workflows sharing smaller functions.

## Commonly Used With

- [Factory Method](factory-method.md) can create the transport used at the opening step.
- [Strategy](strategy.md) can implement an independently selectable operation invoked by the template.
