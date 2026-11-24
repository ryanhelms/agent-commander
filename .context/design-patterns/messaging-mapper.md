---
type: Design Pattern
title: "Messaging Mapper"
description: "Convert between domain objects and wire records in an independently testable component."
family: EIP
category: Messaging Endpoints
tags: ["integration","mapping","wire-format"]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: eip
    resource: https://www.enterpriseintegrationpatterns.com/patterns/messaging/MessagingMapper.html
    title: "Messaging Mapper"
    author: "human:hohpe-woolf"
---

# Messaging Mapper

## When to use

Use when a wire schema and a domain model change at different rates or have different rules for optional fields, trust or versioning.

## Abstract implementation

Place conversions between `ShippingNotice` and `ShipmentRecordV1` in a mapper. Define which fields survive a round trip, which receive defaults and which belong only to the transport.

Example — `domain notice → map to V1 wire fields → encode` and `decode → validate → reconstruct domain notice`

## Concrete implementation

At the sending Commander, map a local `ReviewAssignment` into a versioned request body, then encrypt that body for the target device. Omit the local checkout path and provider credentials. At the receiver, validate the version and map the decrypted request to a local assignment under the receiver’s policy.

## Trade-offs

An apparently harmless default can turn a missing permission into a wider operation. Reject unsupported required fields or versions and test mappings with older records and absent optional values.

## Commonly Used With

- [Canonical Data Model](canonical-data-model.md) supplies the common schema used across participants.
- [Message Translator](message-translator.md) can use the same mapping logic between two wire representations.
