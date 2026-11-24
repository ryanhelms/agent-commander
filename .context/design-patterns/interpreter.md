---
type: Design Pattern
title: Interpreter
description: "An interpreter represents a small language as expressions whose meaning is evaluated against a context."
family: GoF
category: Behavioral
tags:
  - expressions
  - filtering
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: gof
    resource: https://www.informit.com/store/design-patterns-elements-of-reusable-object-oriented-9780201633610
    title: "Design Patterns: Elements of Reusable Object-Oriented Software"
    author: "human:gamma-helm-johnson-vlissides"
---

# Interpreter

## When to use

Use this for a small, stable grammar whose expressions must be composed and evaluated repeatedly. A saved-view filter such as “worker is waiting and host is remote” is a better fit than a general programming language.

## Abstract implementation

Define expression nodes for terminals and grammar operations. Parse the text into those nodes once. Each node evaluates its meaning against an explicit input context. The parser and evaluator can report errors separately.

For example, `And(Flag("ready"), Equal("region", "west")).evaluate(record)` asks both subexpressions to inspect the same record.

## Concrete implementation

An envisioned Go relay could compile a saved agent filter into a tree of equality and conjunction nodes. It would admit only documented fields and operators, bound nesting depth, and evaluate over workers the caller is already entitled to see.

```text
expression = parse('state == "waiting" AND hostKind == "remote"')
tree = checkTypesAndDepth(expression, workerFields)
visible = authorizedWorkers(actor)
return [worker for worker in visible if tree.evaluate(worker)]
```

## Trade-offs

An explicit grammar makes filters explainable and testable. Unsupported syntax should produce an error instead of silently widening the match. A growing language with complex precedence or optimization may merit an established parser or query engine.

## Commonly Used With

- [Composite](composite.md) can represent expression trees with terminal and compound nodes.
- [Visitor](visitor.md) can type-check or explain a parsed expression independently of evaluation.
