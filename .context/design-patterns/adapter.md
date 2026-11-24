---
type: Design Pattern
title: Adapter
description: "An adapter maps an existing component's operations and data to the interface its caller expects."
family: GoF
category: Structural
tags:
  - interfaces
  - translation
status: stable
generated: { by: codex/gpt-6, at: "2026-11-23T21:35:42Z" }
sources:
  - id: gof
    resource: https://www.informit.com/store/design-patterns-elements-of-reusable-object-oriented-9780201633610
    title: "Design Patterns: Elements of Reusable Object-Oriented Software"
    author: "human:gamma-helm-johnson-vlissides"
---

# Adapter

## When to use

Use an adapter when two components already have useful contracts and their names, types or call sequence differ. Check that the underlying component can actually meet the promised behavior, including failures and cancellation.

## Abstract implementation

The client calls a target interface. An object adapter wraps the existing component, translates parameters, delegates the work, and translates results and errors. Keep any behavior the underlying operation cannot represent visible at the boundary.

For example, an adapter can implement `thermometer.celsius()` by reading `sensor.fahrenheit()` and converting the result with `(reading - 32) * 5 / 9`.

## Concrete implementation

An envisioned relay adapter could implement a portable question-reply operation over a provider that requires its own pending-request token. It would resolve the token from the question's recorded session binding and reject a token that no longer belongs to that session.

```text
answer(ctx, questionID, reply):
    binding = pending.require(questionID)
    provider = providers.require(binding.providerID)
    result = provider.reply(ctx, binding.sessionToken, binding.requestToken, reply)
    return mapOutcome(result)
```

## Trade-offs

Consumers can work with one stable interface. Translation becomes unsafe if a provider's acknowledgment only confirms receipt while the interface promises completion. Expose both stages or narrow the interface.

## Commonly Used With

- [Facade](facade.md) can present a small public API that delegates provider-specific calls to adapters.
- [Abstract Factory](abstract-factory.md) can create matching adapters for live operations and historical reads.
- [Message Translator](message-translator.md) can convert event payloads when the adapted operation crosses a messaging boundary.
