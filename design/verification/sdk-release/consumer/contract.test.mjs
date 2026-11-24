import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { fromJson, toJson } from "@bufbuild/protobuf";
import * as sdk from "agent-acp";

const fixture = JSON.parse(readFileSync(new URL("../../../conformance/session.json", import.meta.url), "utf8"));

function scripted(steps) {
  const remaining = [...steps];
  const controller = new AbortController();
  let closed = false;
  let delivered = 0;

  function take(operation, request, signal) {
    assert.equal(signal, controller.signal);
    const step = remaining.shift();
    assert.equal(operation, step?.operation);
    assert.deepEqual(toJson(sdk[`${operation}RequestSchema`], request), step.request);
    return step;
  }

  const client = new sdk.Sessions({
    async unary(operation, request, output, signal) {
      const step = take(operation, request, signal);
      assert.equal(output, sdk[`${operation}ResponseSchema`]);
      return fromJson(output, step.replies[0]);
    },
    async *stream(operation, request, output, signal) {
      const step = take(operation, request, signal);
      assert.equal(output, sdk.ObservationSchema);
      try {
        for (const reply of step.replies) {
          signal.throwIfAborted();
          delivered++;
          yield fromJson(output, reply);
        }
      } finally {
        closed = true;
      }
    }
  });

  return { client, controller, remaining, get closed() { return closed; }, get delivered() { return delivered; } };
}

test("the public client dispatches all shared operations and preserves the observation stream", async () => {
  const run = scripted(fixture);
  for (const step of fixture) {
    const operation = step.operation;
    const input = fromJson(sdk[`${operation}RequestSchema`], step.request);
    const method = operation[0].toLowerCase() + operation.slice(1);
    if (operation === "Observe") {
      const events = [];
      for await (const event of run.client.observe(input, run.controller.signal)) {
        events.push(toJson(sdk.ObservationSchema, event));
      }
      assert.deepEqual(events, step.replies);
      assert.equal(run.closed, true);
    } else {
      const reply = await run.client[method](input, run.controller.signal);
      assert.deepEqual(toJson(sdk[`${operation}ResponseSchema`], reply), step.replies[0]);
    }
  }
  assert.deepEqual(run.remaining, []);
});

test("abort reaches an active stream", async () => {
  const step = fixture.find(s => s.operation === "Observe");
  const run = scripted([step]);
  const input = fromJson(sdk.ObserveRequestSchema, step.request);
  await assert.rejects(async () => {
    for await (const event of run.client.observe(input, run.controller.signal)) {
      assert.deepEqual(toJson(sdk.ObservationSchema, event), step.replies[0]);
      run.controller.abort();
    }
  }, { name: "AbortError" });
  assert.equal(run.delivered, 1);
  assert.equal(run.closed, true);
});
