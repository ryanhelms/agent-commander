---
type: Design Pattern
title: Normalizer
description: "A normalizer translates equivalent inputs from several formats into one representation for downstream consumers."
family: EIP
category: Message Transformation
tags: [eip, message-transformation, format-normalization]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: eip
    resource: https://www.enterpriseintegrationpatterns.com/patterns/messaging/Normalizer.html
    title: Normalizer
    author: 'human:hohpe-woolf'
---

# Normalizer

## When to use

Claude and Codex adapters may describe equivalent tool calls and responses using different field names or event shapes.

## Abstract implementation

Detect the input format and version, dispatch to its translator, and emit one common representation. Preserve source identity, ordering, and information that cannot be mapped safely.

`sourceA.done(id)` and `sourceB.finished(ref)` both map to `Completed(canonicalID)` when the adapters confirm equivalent outcomes.

## Concrete implementation

In a host-side Go adapter, select a decoder from the negotiated protocol and source format. Convert native tool-start events to `ToolStarted{WorkerID, CallID, Name}` and map their results back by call ID. If an event is unknown, retain a typed extension on the authorized host and expose an explicit unsupported state to consumers that lack it.

## Trade-offs

A common representation makes consumers simpler but can obscure real semantic differences. Use golden fixtures from each adapter and keep unrepresentable fields out of misleading defaults.

## Commonly Used With

- [Message Translator](./message-translator.md) — Provide a dedicated translation step for each supported input format.
- [Canonical Data Model](./canonical-data-model.md) — Define the common event semantics that each translator must produce.
