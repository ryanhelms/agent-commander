---
type: Design Pattern
title: Detour
description: "A detour temporarily inserts an additional processing path before messages return to their usual flow."
family: EIP
category: System Management
tags: [eip, system-management, diagnostics]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: eip
    resource: https://www.enterpriseintegrationpatterns.com/patterns/messaging/Detour.html
    title: Detour
    author: 'human:hohpe-woolf'
---

# Detour

## When to use

A relay operator wants to test a new envelope validator on synthetic traffic using the same delivery path as normal traffic.

## Abstract implementation

Place a controllable router before the normal next hop. When a scoped rule matches, pass the message through the extra steps and rejoin the original path. Give the rule an expiration and define what to do if the extra step fails.

`input → optional validator → normal next hop`. Disabling the rule sends subsequent inputs directly to the normal next hop.

## Concrete implementation

On a QA edge, enable a rule matching one enrolled test instance and envelope version. Send matching frames through a metadata validator, then forward each accepted frame once to its usual destination. Reject invalid frames explicitly and expire the rule on schedule. The validator can check frame lengths without access to encrypted content.

## Trade-offs

The extra path adds latency and can change behavior, so a successful baseline matters. Define failure policy before enabling it and ensure a detoured frame cannot circulate back into the same detour.

## Commonly Used With

- [Control Bus](./control-bus.md) — Enable or retire the scoped detour through authenticated administrative commands.
- [Test Message](./test-message.md) — Exercise the detour with an identifiable synthetic case.
