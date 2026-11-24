---
type: Design Pattern
title: Composite
description: "A composite lets clients operate on individual leaves and nested groups through the same interface."
family: GoF
category: Structural
tags:
  - hierarchies
  - groups
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: gof
    resource: https://www.informit.com/store/design-patterns-elements-of-reusable-object-oriented-9780201633610
    title: "Design Patterns: Elements of Reusable Object-Oriented Software"
    author: "human:gamma-helm-johnson-vlissides"
---

# Composite

## When to use

Use a composite when a meaningful operation applies to both one item and a group of items. A good example is resolving a message audience that may name a worker, a team, or a team containing smaller teams.

## Abstract implementation

Define a component operation. A leaf supplies its own result, while a composite combines the results of its children. For data that permits overlapping membership, define identity, duplicate handling and cycle detection when traversing the structure.

For example, `file.bytes()` returns a stored length and `folder.bytes()` sums `child.bytes()` over its children. An inventory can ask either one for its size.

## Concrete implementation

A proposed Commander relay could resolve a nested project group against a fixed membership revision. It would collect unique worker IDs before evaluating each recipient's consent. A cyclic membership record would fail expansion explicitly, keeping partial audiences out of the delivery queue.

```text
expand(node, revision, ancestors):
    if node is Worker: return {node.id}
    if node.id in ancestors: fail("cyclic group")
    children = memberships.at(revision, node.id)
    return union(expand(child, revision, ancestors + {node.id}) for child in children)
```

## Trade-offs

A uniform interface makes nested groups easy to compose. It can also imply that every operation on a worker makes sense for a group. Keep individual actions such as granting a terminal lease on the leaf interface.

## Commonly Used With

- [Iterator](iterator.md) can traverse the hierarchy for callers that need one recipient at a time.
- [Visitor](visitor.md) can perform additional operations across the same group and worker types.
