---
type: Design Pattern
title: Canonical Data Model
description: "A shared data model gives independent integrations one agreed representation of common domain concepts."
family: EIP
category: Message Transformation
tags: [eip, message-transformation, shared-schema]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: eip
    resource: https://www.enterpriseintegrationpatterns.com/patterns/messaging/CanonicalDataModel.html
    title: Canonical Data Model
    author: 'human:hohpe-woolf'
---

# Canonical Data Model

## When to use

Relays, harness adapters, and native consoles otherwise need a separate mapping for each producer and consumer pair.

## Abstract implementation

Define a minimal canonical vocabulary with stable identities, types, state transitions, and versioning. Map each participant at the boundary and use extensions for genuinely source-specific data.

`AdapterA ↔ WorkerEvent/v1 ↔ AdapterB` defines one shared event contract with a mapping at each boundary.

## Concrete implementation

Define a versioned worker-event contract that distinguishes an offered job, a receiver-accepted reservation, an actual start, and completion. Map each provider independently to these concepts. Keep worker ID, operation ID, and transport delivery ID in separate fields, and let a common projector serve both console renderers.

## Trade-offs

A shared schema lowers pairwise translation cost but becomes a coordination point. Collapsing distinct provider states into a broad `success` value can make failed or incomplete actions look final.

## Commonly Used With

- [Normalizer](./normalizer.md) — Converge several native inputs on the shared representation.
- [Message Translator](./message-translator.md) — Translate canonical values into consumer-specific formats at the edge.
