---
type: Design Pattern
title: Builder
description: "A builder assembles a complex product in stages and exposes it once its required parts agree."
family: GoF
category: Creational
tags:
  - construction
  - validation
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: gof
    resource: https://www.informit.com/store/design-patterns-elements-of-reusable-object-oriented-9780201633610
    title: "Design Patterns: Elements of Reusable Object-Oriented Software"
    author: "human:gamma-helm-johnson-vlissides"
---

# Builder

## When to use

Use a builder when several independently supplied options must become one valid, immutable request. It earns its cost when callers construct different useful configurations or use the same construction steps for different representations.

## Abstract implementation

The builder owns incomplete state. Its operations collect parts and its final operation checks invariants before returning a product. A director can run a repeatable sequence for different builders. A single configuration struct with validation works well when every caller supplies the same inputs together.

For example, `recipe.assemble(builder)` can add chapters to a document builder or sections to a web builder, and `builder.finish()` returns the completed representation.

## Concrete implementation

A proposed relay invitation builder could assemble the grantee, allowed operations and expiration. A reusable read-only invitation recipe would set the same operation set every time. Signing would occur only after the builder validates the finished scope.

```text
draft = newInvitationBuilder()
draft.forRecipient(teammate.id)
draft.allow("read-result")
draft.expiresAt(shiftEnd)
invitation = signer.sign(draft.buildOrError())
```

## Trade-offs

Partial state makes the order of operations worth testing. Reusing a mutable builder across requests could carry a previous recipient into a new invitation. Construct a fresh builder or return immutable copies.

## Commonly Used With

- [Abstract Factory](abstract-factory.md) can provide builders configured for a particular signing and serialization family.
- [Prototype](prototype.md) can seed a builder from an approved template before per-request fields are set.
