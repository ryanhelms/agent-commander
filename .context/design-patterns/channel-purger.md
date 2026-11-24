---
type: Design Pattern
title: Channel Purger
description: "A channel purger removes unwanted messages from a bounded channel under an explicit cleanup policy."
family: EIP
category: System Management
tags: [eip, system-management, channel-cleanup]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: eip
    resource: https://www.enterpriseintegrationpatterns.com/patterns/messaging/ChannelPurger.html
    title: Channel Purger
    author: 'human:hohpe-woolf'
---

# Channel Purger

## When to use

A disposable integration test reuses a durable channel and pending messages from an earlier test could satisfy the next test incorrectly.

## Abstract implementation

Identify the exact channel, establish which messages are obsolete, and coordinate producers and consumers before removing or draining that set. Verify the cleanup boundary afterward.

`pauseFixture → record(highWater) → discard(testChannel, through: highWater) → verify → resume`.

## Concrete implementation

Give each relay test suite an isolated stream. At teardown, stop its fixture publisher, record the final sequence, and purge that stream's messages through that boundary. Check that its pending count has returned to the expected value before reusing the fixture. Do not apply a reusable test cleanup rule to shared job or receipt storage.

## Trade-offs

Purging is destructive and can race with current delivery. Prefer separate fixture channels when possible, require a precise subject and sequence boundary, and account for consumer acknowledgements separately.

## Commonly Used With

- [Control Bus](./control-bus.md) — Restrict purge commands to the owner of the named test channel.
- [Test Message](./test-message.md) — Prove the next run observes its own synthetic messages after cleanup.
