---
type: Design Pattern
title: "File Transfer"
description: "Applications exchange data by publishing complete files that another application imports on its own schedule."
family: EIP
category: "Integration Styles"
tags: ["eip","batch","integration"]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: eip
    resource: https://www.enterpriseintegrationpatterns.com/patterns/messaging/FileTransferIntegration.html
    title: "File Transfer"
    author: 'human:hohpe-woolf'
---

# File Transfer

## When to use

A producer can export a snapshot, the recipient already understands files, and hourly or daily latency fits the workflow.

## Abstract implementation

Agree on the file format and how the receiver distinguishes a complete batch. The producer writes a new file and publishes a completion marker. The importer records which batches it has committed so a second pickup is safe.

`write(batch.tmp) → close → rename(batch.tmp, batch.ready) → import_once(batch.id)`

## Concrete implementation

A usage accountant could write an hourly CSV and a manifest into a temporary directory. After closing both files, it renames the directory into the billing importer’s inbox on the same filesystem. The importer checks the digest and commits the billing rows and batch ID in one database transaction.

## Trade-offs

Large batches are inexpensive to move and easy to inspect. Partially written files, republished batches and incompatible column changes require explicit handling. Size and time between batches bound freshness.

## Commonly Used With

- A version in the manifest selects the column mapping. [Format Indicator](format-indicator.md)
- A smaller snapshot can use the same document contract when sent over a message transport. [Document Message](document-message.md)
