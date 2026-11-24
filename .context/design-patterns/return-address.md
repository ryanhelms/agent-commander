---
type: Design Pattern
title: "Return Address"
description: "A requester includes the destination to which its reply should be sent."
family: EIP
category: "Message Construction"
tags: ["eip","reply-routing","addresses"]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: eip
    resource: https://www.enterpriseintegrationpatterns.com/patterns/messaging/ReturnAddress.html
    title: "Return Address"
    author: 'human:hohpe-woolf'
---

# Return Address

## When to use

Different callers or conversations expect answers on different channels, so the responder needs a destination for each request.

## Abstract implementation

Place the reply destination in the request envelope. The responder uses it when creating a separate reply message. Define the lifetime, scope and permissions for dynamically allocated addresses.

`request.replyTo = "inbox.A" → responder validates route → send("inbox.A", result)`

## Concrete implementation

A coordinator could allocate a short-lived reply inbox from its own tenant namespace. The worker checks the signed request and verifies that its reply permission covers that inbox before publishing its sealed result. The coordinator keeps the subscription until completion or deadline.

## Trade-offs

An unchecked return address can route confidential results to an unintended party. Short-lived inboxes can disappear before slower replies arrive. Constrain permitted destinations and align address lifetime with the delivery policy.

## Commonly Used With

- The return address supplies the destination for the reply half of the exchange. [Request-Reply](request-reply.md)
- A shared reply inbox still needs a key to distinguish simultaneous requests. [Correlation Identifier](correlation-identifier.md)
