---
type: Design Pattern
title: "Format Indicator"
description: "A message declares the format needed to interpret its content."
family: EIP
category: "Message Construction"
tags: ["eip","encoding","versioning"]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: eip
    resource: https://www.enterpriseintegrationpatterns.com/patterns/messaging/FormatIndicator.html
    title: "Format Indicator"
    author: 'human:hohpe-woolf'
---

# Format Indicator

## When to use

Several payload representations, character encodings or schema versions can reach the same receiver.

## Abstract implementation

Choose agreed identifiers for the relevant formats and define their decoding rules. Put the identifier where the intended decoder can read it. Unrecognized values should take an explicit compatibility or failure path.

`decode = decoders[(header.mediaType, header.schemaVersion)] → decode(payload)`

## Concrete implementation

An authorized endpoint could decrypt an envelope and read `media_type` and `schema_version` from its authenticated inner header. Its decoder table accepts `application/json` with `task.v2`, applies that version’s field rules and records an unsupported-format reason for any unknown pair.

## Trade-offs

A declared format does not prove the bytes conform. Validate size and structure while decoding. Put private type information inside the encrypted content when intermediate routing does not require it.

## Commonly Used With

- A supported older format can be decoded and mapped into the receiver’s model. [Message Translator](message-translator.md)
- Unsupported identifiers or malformed encodings can be preserved for diagnosis. [Invalid Message Channel](invalid-message-channel.md)
