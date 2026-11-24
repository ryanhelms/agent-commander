---
type: Design Pattern
title: "Channel Adapter"
description: "An adapter connects an application's existing interface to a messaging channel."
family: EIP
category: "Messaging Channels"
tags: ["eip","integration","boundary"]
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: eip
    resource: https://www.enterpriseintegrationpatterns.com/patterns/messaging/ChannelAdapter.html
    title: "Channel Adapter"
    author: 'human:hohpe-woolf'
---

# Channel Adapter

## When to use

An application exposes a file, database, callback or API and cannot itself participate in a messaging transport.

## Abstract implementation

Bind an inbound or outbound channel to that interface. Translate between the application's operation and a message, including the point at which the adapter can record progress or acknowledge delivery.

`poll(legacyResults, after=cursor) → publish(ResultSeen(row.id)) → confirm → advance(cursor)`

## Concrete implementation

A Go adapter could poll a legacy test runner’s append-only results table using an increasing result ID. It publishes a result event with that ID, waits for durable acceptance and advances its checkpoint. Polling resumes at the saved position on restart.

## Trade-offs

Polling adds latency and may miss changes if the source lacks a reliable ordering key. A crash between publication and checkpoint can emit the same result twice. Isolate transport errors from failures reported by the underlying application.

## Commonly Used With

- Each completed result row can become an event for subscribers. [Event Message](event-message.md)
- A mapping converts the runner’s row into the agreed result schema. [Message Translator](message-translator.md)
