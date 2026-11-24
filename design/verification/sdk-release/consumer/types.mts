import { create } from "@bufbuild/protobuf";
import { ObserveRequestSchema, SendRequestSchema, Sessions } from "agent-acp";
import type { Observation, Runtime, SendResponse, SessionRef } from "agent-acp";

export function sendAndObserve(runtime: Runtime, ref: SessionRef, signal: AbortSignal) {
  const sessions = new Sessions(runtime);
  const receipt: Promise<SendResponse> = sessions.send(
    create(SendRequestSchema, { session: ref, operationId: "example", text: "Hello" }), signal,
  );
  const observations: AsyncIterable<Observation> = sessions.observe(
    create(ObserveRequestSchema, { session: ref }), signal,
  );
  return { receipt, observations };
}
