---
type: Design Pattern
title: "Shared Database"
description: "Several applications integrate by reading and updating a common data model in one database."
family: EIP
category: "Integration Styles"
tags: ["eip","transactions","schema"]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: eip
    resource: https://www.enterpriseintegrationpatterns.com/patterns/messaging/SharedDataBaseIntegration.html
    title: "Shared Database"
    author: 'human:hohpe-woolf'
---

# Shared Database

## When to use

Two trusted applications need the same committed records and can coordinate schema changes and write ownership.

## Abstract implementation

Give each shared concept one representation. Specify who can change each field, enforce common constraints in the database and use transactions when two records must change together.

`allocator commits Reservation(42, 3) → scheduler reads that same row from the shared ledger`

## Concrete implementation

A local admin process and billing worker could share an allocation ledger. The worker locks the allocation, inserts a charge with a unique operation ID, decrements the remaining units and commits. The admin process reads the resulting balance from that same ledger.

## Trade-offs

Concurrent writes can enforce an invariant in one place. A schema migration or a long-running transaction now affects every participant. Table permissions must also preserve which principals may see each record.

## Commonly Used With

- A committed row change can produce a notification for readers that should refresh. [Event Message](event-message.md)
- A service can own the sensitive update while other applications keep read-only database access. [Remote Procedure Invocation](remote-procedure-invocation.md)
