---
type: Design Pattern
title: Routing Slip
description: "A routing slip carries an ordered list of processing steps for one message."
family: EIP
category: Message Routing
tags: [eip, message-routing, itinerary]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: eip
    resource: https://www.enterpriseintegrationpatterns.com/patterns/messaging/RoutingTable.html
    title: Routing Slip
    author: 'human:hohpe-woolf'
---

# Routing Slip

## When to use

An authorized export may need validation alone or validation followed by artifact assembly and receipt creation. The sequence varies per export.

## Abstract implementation

Build a per-message itinerary from an allowlisted vocabulary. Each stage completes its step, advances a cursor, and forwards the message to the named next stage.

`steps = [check, render, export]`, `cursor = 1` selects `render`. On success, advance to `2` and hand off to `export`.

## Concrete implementation

The receiver can compile an export plan to `[validateManifest, buildArtifact, writeReceipt]`. Store its digest and cursor with the job. Each stage verifies the digest, records its result under `(jobID, stepIndex)`, and hands off after committing. Reject arbitrary executable names and network addresses in supplied plans.

## Trade-offs

A fixed itinerary is straightforward to audit. Long-running jobs may outlive a stage version, so pin the plan semantics and define how an interrupted handoff resumes.

## Commonly Used With

- [Process Manager](./process-manager.md) — Coordinate workflows where the next steps depend on external events.
- [Idempotent Receiver](./idempotent-receiver.md) — Make a repeated handoff safe after an interrupted transition.
