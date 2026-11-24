---
type: Design Pattern
title: Visitor
description: "A visitor adds type-specific operations over a stable family of elements while keeping those operations together."
family: GoF
category: Behavioral
tags:
  - traversal
  - typed-operations
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: gof
    resource: https://www.informit.com/store/design-patterns-elements-of-reusable-object-oriented-9780201633610
    title: "Design Patterns: Elements of Reusable Object-Oriented Software"
    author: "human:gamma-helm-johnson-vlissides"
---

# Visitor

## When to use

Use a visitor when an element family changes slowly but new operations over that family arrive frequently. For example, a relay policy tree may need an evaluator, an explanation for its owner and a static complexity check.

## Abstract implementation

Each concrete element accepts a visitor and dispatches to its own type-specific visit method. The visitor defines one method per element type. Traversal can live in the visitor or in a separate walker, but exactly one participant should control recursion.

For example, `invoice.accept(taxVisitor)` dispatches to `taxVisitor.visitInvoice(invoice)`, while a credit note dispatches to `visitCreditNote`. A separate export visitor can handle both document types.

## Concrete implementation

A proposed permission inspector could explain a composed policy. Each node would dispatch to a clause-specific formatter. The conjunction formatter would visit its children in order. A separate evaluator could traverse the same policy using the same visitor contract.

```text
RoleClause.accept(visitor) = visitor.role(self)
AllOf.accept(visitor) = visitor.allOf(self)
Explain.role(node) = "requires role " + node.roleName
Explain.allOf(node) = join(" and ", [child.accept(self) for child in node.children])
text = policy.root.accept(Explain())
```

## Trade-offs

Visitors group each operation's logic, which makes adding an operation straightforward. Adding an element type requires updating every visitor. Make omissions visible in compilation or tests, especially for policy types that affect authorization.

## Commonly Used With

- [Composite](composite.md) can supply the element hierarchy accepted by the visitor.
- [Interpreter](interpreter.md) can use separate visitors to explain or type-check an expression before evaluation.
