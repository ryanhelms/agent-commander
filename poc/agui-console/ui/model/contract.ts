// The data contract between the console and the backend. Nothing here invents values: state and
// messages are read from AG-UI as published, and anything missing stays missing.

export const AGENT_ID = "claude";
export const THREAD_ID = "claude-console";
export const REPLY_URL = "/reply";

export type SessionStatus = "working" | "waiting" | "completed" | "failed" | "stopped";

export interface ConsoleRequest {
  id: string;
  question: string;
  status: "pending" | "answered";
  answer?: string;
}

export interface ConsoleState {
  status?: SessionStatus;
  runId?: string;
  requests: ConsoleRequest[];
  error?: string;
}

const STATUSES: readonly string[] = ["working", "waiting", "completed", "failed", "stopped"];

function text(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

/** Reads agent.state defensively: the state is empty until the backend publishes its first snapshot. */
export function readState(raw: unknown): ConsoleState {
  const source = raw && typeof raw === "object" ? (raw as Record<string, unknown>) : {};
  const requests: ConsoleRequest[] = [];
  if (Array.isArray(source.requests)) {
    for (const item of source.requests) {
      if (!item || typeof item !== "object") continue;
      const record = item as Record<string, unknown>;
      const id = text(record.id);
      if (!id) continue;
      requests.push({
        id,
        question: text(record.question) ?? "",
        status: record.status === "answered" ? "answered" : "pending",
        answer: text(record.answer),
      });
    }
  }
  const status = text(source.status);
  return {
    status: status && STATUSES.includes(status) ? (status as SessionStatus) : undefined,
    runId: text(source.runId),
    requests,
    error: text(source.error),
  };
}

// ---- Timeline ----

export type TimelineEntry =
  | { kind: "message"; id: string; speaker: "assistant" | "user"; text: string }
  | {
      kind: "activity";
      id: string;
      name: string;
      /** A shell command when the tool call carries one, shown as `$ command`. */
      command?: string;
      /** The tool arguments as written by the agent, pretty-printed when they are JSON. */
      input: string;
      /** The tool arguments exactly as received. */
      raw: string;
      /** The tool-role message for this call, once it exists. */
      result?: string;
      failed: boolean;
    };

/** Structural view of the AG-UI message shapes this console renders. */
interface WireMessage {
  id?: string;
  role?: string;
  content?: unknown;
  toolCalls?: Array<{ id?: string; function?: { name?: string; arguments?: string } }>;
  toolCallId?: string;
  error?: string;
}

function contentText(content: unknown): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content
      .map((part) =>
        part && typeof part === "object" && typeof (part as { text?: unknown }).text === "string"
          ? (part as { text: string }).text
          : "",
      )
      .join("");
  }
  return "";
}

function formatArguments(raw: string | undefined): { command?: string; input: string } {
  if (!raw) return { input: "" };
  try {
    const parsed: unknown = JSON.parse(raw);
    if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
      const record = parsed as Record<string, unknown>;
      const command = text(record.command);
      if (command) {
        const { command: _omit, ...rest } = record;
        return { command, input: Object.keys(rest).length ? JSON.stringify(rest, null, 2) : "" };
      }
    }
    return { input: JSON.stringify(parsed, null, 2) };
  } catch {
    // Arguments are still streaming or are not JSON; show them as written.
    return { input: raw };
  }
}

/**
 * Turns agent.messages into the visible timeline: assistant and user text become conversation
 * entries, and every assistant tool call becomes its own activity entry joined to its tool-role result.
 */
export function buildTimeline(rawMessages: unknown): TimelineEntry[] {
  const messages: WireMessage[] = Array.isArray(rawMessages) ? (rawMessages as WireMessage[]) : [];
  const results = new Map<string, { content: string; failed: boolean }>();
  for (const message of messages) {
    if (message?.role === "tool" && message.toolCallId) {
      const body = contentText(message.content);
      results.set(message.toolCallId, {
        content: body || message.error || "",
        failed: Boolean(message.error),
      });
    }
  }

  const entries: TimelineEntry[] = [];
  messages.forEach((message, index) => {
    if (!message) return;
    const id = message.id ?? `message-${index}`;
    if (message.role === "user") {
      const body = contentText(message.content);
      if (body.trim()) entries.push({ kind: "message", id, speaker: "user", text: body });
      return;
    }
    if (message.role !== "assistant") return;
    const body = contentText(message.content);
    if (body.trim()) entries.push({ kind: "message", id, speaker: "assistant", text: body });
    (message.toolCalls ?? []).forEach((call, callIndex) => {
      const callId = call.id ?? `${id}-call-${callIndex}`;
      const result = call.id ? results.get(call.id) : undefined;
      entries.push({
        kind: "activity",
        id: callId,
        name: call.function?.name || "tool",
        ...formatArguments(call.function?.arguments),
        raw: call.function?.arguments ?? "",
        result: result?.content,
        failed: result?.failed ?? false,
      });
    });
  });
  return entries;
}

// ---- Scrollback ----

export type ScreenItem = TimelineEntry | { kind: "request"; id: string; request: ConsoleRequest };

/**
 * Places each Commander request in the scrollback. Requests live in state, not in messages, so a
 * request sits directly after the tool call whose arguments carry its id or its exact question;
 * a request with no such call follows the transcript.
 */
export function buildScrollback(timeline: TimelineEntry[], requests: ConsoleRequest[]): ScreenItem[] {
  const after = new Map<string, ConsoleRequest[]>();
  const trailing: ConsoleRequest[] = [];
  const claimed = new Set<string>();

  for (const request of requests) {
    const needle = request.question ? JSON.stringify(request.question).slice(1, -1) : undefined;
    const anchor = timeline.find(
      (entry) =>
        entry.kind === "activity" &&
        !claimed.has(entry.id) &&
        (entry.raw.includes(request.id) || (needle !== undefined && entry.raw.includes(needle))),
    );
    if (anchor) {
      claimed.add(anchor.id);
      after.set(anchor.id, [...(after.get(anchor.id) ?? []), request]);
    } else {
      trailing.push(request);
    }
  }

  const items: ScreenItem[] = [];
  const push = (request: ConsoleRequest) => items.push({ kind: "request", id: `request-${request.id}`, request });
  for (const entry of timeline) {
    items.push(entry);
    after.get(entry.id)?.forEach(push);
  }
  trailing.forEach(push);
  return items;
}

// ---- Presentation of status ----

/** Terminal ink roles. Each is always paired with a glyph or a word, never used alone. */
export type Ink = "bright" | "dim" | "cyan" | "violet" | "amber" | "green" | "red";

export interface StatusView {
  label: string;
  glyph: string;
  ink: Ink;
  live: boolean;
}

export function statusPresentation(status: SessionStatus | undefined, started: boolean): StatusView {
  switch (status) {
    case "working":
      return { label: "working", glyph: "●", ink: "green", live: true };
    case "waiting":
      return { label: "needs input", glyph: "?", ink: "amber", live: true };
    case "completed":
      return { label: "completed", glyph: "✓", ink: "green", live: false };
    case "failed":
      return { label: "failed", glyph: "✗", ink: "red", live: false };
    case "stopped":
      return { label: "stopped", glyph: "■", ink: "dim", live: false };
    default:
      return started
        ? { label: "starting", glyph: "…", ink: "dim", live: true }
        : { label: "not started", glyph: "○", ink: "dim", live: false };
  }
}
