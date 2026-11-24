---
type: Design Pattern
title: Flyweight
description: "A flyweight shares immutable intrinsic data among many instances while callers supply their changing context."
family: GoF
category: Structural
tags:
  - memory
  - sharing
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: gof
    resource: https://www.informit.com/store/design-patterns-elements-of-reusable-object-oriented-9780201633610
    title: "Design Patterns: Elements of Reusable Object-Oriented Software"
    author: "human:gamma-helm-johnson-vlissides"
---

# Flyweight

## When to use

Consider flyweights when measurements show that many simultaneously retained objects contain the same expensive data. For example, thousands of delivery records might each own a decoded copy of the same versioned schema.

## Abstract implementation

Separate intrinsic state from per-use state. A factory interns intrinsic objects by a key that fully identifies their meaning. Callers pass recipient-specific values into operations rather than placing those values in the shared object.

For example, `glyphPool.get(font, character).draw(canvas, x, y)` shares the glyph outline while each call supplies its own canvas and position.

## Concrete implementation

An envisioned Go relay could share one compiled schema per digest while validating a batch of deliveries. Each validation call would supply the individual payload and its bounds. A bounded cache would evict seldom-used schemas.

```text
schema = compiledSchemas.getOrCompile(event.schemaDigest)
for delivery in batch:
    verdict = schema.validate(delivery.payload, limitsFor(delivery.recipient))
    record(delivery.id, verdict)
```

## Trade-offs

Sharing lowers memory use at the cost of lookup and cache management. Putting mutable tenant options or private payloads into the interned object risks cross-request contamination. Benchmark against decoding once per batch before adding a global cache.

## Commonly Used With

- [Factory Method](factory-method.md) can return an interned product when the creation hook receives the same intrinsic key.
- [Composite](composite.md) can reuse immutable leaf descriptions across many independently positioned nodes.
