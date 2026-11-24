---
type: Design Pattern
title: "Message Expiration"
description: "A message carries a validity limit after which the system stops delivering or acting on it."
family: EIP
category: "Message Construction"
tags: ["eip","deadlines","freshness"]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: eip
    resource: https://www.enterpriseintegrationpatterns.com/patterns/messaging/MessageExpiration.html
    title: "Message Expiration"
    author: 'human:hohpe-woolf'
---

# Message Expiration

## When to use

A late message loses its value or a delayed command could cause an incorrect action.

## Abstract implementation

Assign an absolute expiry or a relative lifetime with a defined starting point. Check it where the message waits and again at the point of action. Forwarding and retry must preserve the remaining lifetime.

`accepted at 10:02, expires at 10:05 → retry at 10:06 → discard before execution`

## Concrete implementation

A temporary run invitation could carry a signed `expires_at`. The relay drops expired envelopes from its queue, and the recipient checks the signed deadline against its trusted clock before accepting an invitation that arrived just before expiry.

## Trade-offs

Clock skew and delayed processing complicate the final boundary. Specify the permitted skew and who sets the deadline. A queue’s retention period can remove stored data but cannot revoke an action a recipient already took.

## Commonly Used With

- Execution checks can reject an otherwise valid command whose opportunity has passed. [Command Message](command-message.md)
- A system can retain a restricted diagnostic record for expired deliveries when its policy calls for one. [Dead Letter Channel](dead-letter-channel.md)
