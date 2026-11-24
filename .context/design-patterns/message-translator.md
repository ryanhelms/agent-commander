---
type: Design Pattern
title: "Message Translator"
description: "A boundary component converts a message between representations while preserving its business meaning."
family: EIP
category: "Messaging Systems"
tags: ["eip","mapping","compatibility"]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: eip
    resource: https://www.enterpriseintegrationpatterns.com/patterns/messaging/MessageTranslator.html
    title: "Message Translator"
    author: 'human:hohpe-woolf'
---

# Message Translator

## When to use

A producer and consumer have compatible semantics but use different field names, structures or value conventions.

## Abstract implementation

Specify the source and destination schemas, map fields and units explicitly, and define what happens when a source value cannot be represented. Keep the identity needed by the receiving workflow.

`map(LegacyDuration{seconds: 3}) → DurationV2{milliseconds: 3000}`

## Concrete implementation

A local provider adapter could map a native tool-finished record to a conversation event. It copies the original call ID, maps the provider’s failure flag to the event status and keeps the result bytes in the declared content type. A missing call ID causes a validation error.

## Trade-offs

Lossy conversions can turn a failed operation into apparent success. Keep representative fixtures for unknown enum values, absent fields and differing units. Perform content translation where plaintext access is authorized.

## Commonly Used With

- An explicit source schema selects the correct translator. [Format Indicator](format-indicator.md)
- A protocol-facing adapter can invoke the mapping before it sends the translated message. [Channel Adapter](channel-adapter.md)
