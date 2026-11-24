---
type: Design Pattern
title: Prototype
description: "A prototype produces a new object by copying an existing example and defining which state the copy owns."
family: GoF
category: Creational
tags:
  - construction
  - copying
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: gof
    resource: https://www.informit.com/store/design-patterns-elements-of-reusable-object-oriented-9780201633610
    title: "Design Patterns: Elements of Reusable Object-Oriented Software"
    author: "human:gamma-helm-johnson-vlissides"
---

# Prototype

## When to use

Use this when a configured example is expensive to assemble or users start from named templates and adjust a few fields. First decide which values are configuration and which record a particular running instance.

## Abstract implementation

Expose a clone operation on the product. Each prototype decides how to copy its internals, including nested mutable containers. The caller can clone an instance through an interface without knowing the concrete representation.

For example, `a = template.clone()` and `b = template.clone()` produce two schedules. Moving an appointment in `a` leaves both `b` and the original template intact.

## Concrete implementation

In a proposed relay deployment, an operator could create a worker policy from a research profile. Its role and tool rules would carry over. The caller would issue a new policy ID, and the clone would start with a fresh budget and no active grants.

```text
cloneProfile(base):
    copy = newProfile(id = newID())
    copy.allowedTools = deepCopy(base.allowedTools)
    copy.limits = valueCopy(base.limits)
    return copy
```

## Trade-offs

Cloning preserves nuanced configuration but can also reproduce stale authority or accidentally share mutable state. Test that adding a tool to the clone leaves the source unchanged and that both instances have separate accounting.

## Commonly Used With

- [Builder](builder.md) can finish a cloned profile by supplying recipient-specific limits and validating the whole policy.
- [Factory Method](factory-method.md) can clone a registered prototype when the creator needs another configured product.
