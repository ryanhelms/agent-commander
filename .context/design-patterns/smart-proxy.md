---
type: Design Pattern
title: Smart Proxy
description: "A smart proxy tracks a request and its reply by substituting its own return address and forwarding the response."
family: EIP
category: System Management
tags: [eip, system-management, reply-routing]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: eip
    resource: https://www.enterpriseintegrationpatterns.com/patterns/messaging/SmartProxy.html
    title: Smart Proxy
    author: 'human:hohpe-woolf'
---

# Smart Proxy

## When to use

A caller uses a temporary connection while a downstream service replies asynchronously. The intermediary must observe the response and route it back to the right caller.

## Abstract implementation

Save the original reply address and request correlation, substitute a proxy-owned reply address, and forward the request. On the reply path, restore the caller's routing information and release the mapping under a defined completion policy.

`callerReply → save(handle, callerReply) → substitute(proxyReply)` on the request. `reply(handle) → lookup(handle) → callerReply` on the return path.

## Concrete implementation

An edge could assign a short-lived opaque reply handle to a forwarded observation request. Store the mapping to the authorized inbound stream and original correlation ID, and put the proxy's inbox in a mutable outer header. When a reply arrives from the expected host, check the handle and route generation, then forward its untouched encrypted body. Expire mappings on disconnect or deadline.

## Trade-offs

The intermediary holds per-request state and can lose it on restart. Use host-side operation receipts for reconciliation when a client times out. An edge acknowledgement alone cannot establish that a job ran.

## Commonly Used With

- [Return Address](./return-address.md) — Identify the caller's destination before substituting the proxy's inbox.
- [Correlation Identifier](./correlation-identifier.md) — Match incoming replies to stored mappings without inspecting encrypted payloads.
