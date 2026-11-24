---
type: Design Pattern
title: "Pipes and Filters"
description: "A pipeline decomposes processing into stages connected by channels with explicit input and output contracts."
family: EIP
category: "Messaging Systems"
tags: ["eip","pipeline","composition"]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: eip
    resource: https://www.enterpriseintegrationpatterns.com/patterns/messaging/PipesAndFilters.html
    title: "Pipes and Filters"
    author: 'human:hohpe-woolf'
---

# Pipes and Filters

## When to use

Several transformations recur in different flows or need independent scaling and failure handling.

## Abstract implementation

Give each filter one input contract and one output contract. Pipes carry the output of one filter to the next. Separate stages only where the output remains meaningful on its own.

`records → parse → validated rows → aggregate → daily totals`

## Concrete implementation

An endpoint-local transcript importer could compose `decodeRecord → normalizeTimestamp → redactSecrets → index`. Each stage emits a typed value. A failed redaction check prevents the index stage from receiving that record. Plaintext stays inside the authorized endpoint.

## Trade-offs

Stages can be tested and replaced independently. Extra queues add buffering, ordering questions and new places for sensitive data to persist. An in-process iterator can serve as a pipe when durability between stages has no value.

## Commonly Used With

- A format conversion fits into one independently tested filter. [Message Translator](message-translator.md)
- A failing validation stage can route rejected records for scoped inspection. [Invalid Message Channel](invalid-message-channel.md)
