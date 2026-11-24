---
type: Design Pattern
title: "Document Message"
description: "A sender transfers a self-contained representation of data for the receiver to use."
family: EIP
category: "Message Construction"
tags: ["eip","data-exchange","snapshot"]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: eip
    resource: https://www.enterpriseintegrationpatterns.com/patterns/messaging/DocumentMessage.html
    title: "Document Message"
    author: 'human:hohpe-woolf'
---

# Document Message

## When to use

Another application needs a complete dataset or snapshot and can choose what to do with it.

## Abstract implementation

Package the data with its scope and version. The receiver may store it, compare it to a previous revision or pass it on. Define whether the document represents a complete replacement or a partial view.

`RosterSnapshot{workspace: "blue", revision: 8, complete: true, members: [...]}`

## Concrete implementation

An owner device could send an encrypted workspace roster document with a workspace ID, revision and the complete member list. A recipient verifies the signature and scope, then replaces the cached roster only if the document is complete and its revision is newer.

## Trade-offs

Large snapshots increase transfer and storage costs. Empty collections, omitted fields and out-of-order revisions can produce different results unless the document contract defines their meaning.

## Commonly Used With

- A declared representation lets a receiver interpret an incoming document. [Format Indicator](format-indicator.md)
- A large or infrequent document can travel as a batch file. [File Transfer](file-transfer.md)
