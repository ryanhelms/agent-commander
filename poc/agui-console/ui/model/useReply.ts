import React from "react";
import { REPLY_URL } from "./contract";

// Reply delivery through the existing Commander API. A reply is only "answered" when agent.state
// says so; a successful POST moves the request to "sent" and the card keeps waiting for state.

export type ReplyPhase =
  | { phase: "idle" }
  | { phase: "sending" }
  | { phase: "sent" }
  | { phase: "error"; message: string };

function newOperationId(): string {
  if (typeof crypto !== "undefined" && typeof crypto.randomUUID === "function") {
    return crypto.randomUUID();
  }
  const bytes = new Uint8Array(16);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

export function useReply() {
  const [phases, setPhases] = React.useState<Record<string, ReplyPhase>>({});
  // A retry of the same answer reuses its operation id, so the backend can treat it as one operation.
  const attempts = React.useRef<Record<string, { answer: string; operationId: string }>>({});

  const send = React.useCallback(async (requestId: string, answer: string) => {
    const previous = attempts.current[requestId];
    const operationId = previous && previous.answer === answer ? previous.operationId : newOperationId();
    attempts.current[requestId] = { answer, operationId };
    setPhases((current) => ({ ...current, [requestId]: { phase: "sending" } }));
    try {
      const response = await fetch(REPLY_URL, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ requestId, answer, operationId }),
      });
      if (!response.ok) {
        const detail = (await response.text().catch(() => "")).trim();
        throw new Error(detail || `The reply was not accepted (HTTP ${response.status}).`);
      }
      setPhases((current) => ({ ...current, [requestId]: { phase: "sent" } }));
    } catch (error) {
      const message = error instanceof Error ? error.message : "The reply could not be sent.";
      setPhases((current) => ({ ...current, [requestId]: { phase: "error", message } }));
    }
  }, []);

  const phaseOf = React.useCallback(
    (requestId: string): ReplyPhase => phases[requestId] ?? { phase: "idle" },
    [phases],
  );

  return { send, phaseOf };
}
