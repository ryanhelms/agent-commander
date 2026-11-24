// The data contract between the console and the backend. Nothing here invents values: state and
// messages are read from AG-UI as published, and anything missing stays missing.
import { providerPromptReference, type ProviderPromptReference } from "../../connector/provider-media.mjs";

export const AGENT_ID = "commander";
export const THREAD_ID = "claude-console";
export const REPLY_URL = "/reply";

type SourceMedia = { kind: "image" | "audio"; url: string };
const IMAGE_MIME = new Set(["image/png", "image/jpeg", "image/gif", "image/webp", "image/avif"]);
const AUDIO_MIME = new Set(["audio/wav", "audio/mpeg", "audio/mp4", "audio/ogg", "audio/webm"]);

export function inlineSourceMedia(mime?: string, bytes?: string): SourceMedia | undefined {
  if (!mime || !bytes || !/^[A-Za-z0-9+/]+={0,2}$/u.test(bytes)) return undefined;
  const url = `data:${mime};base64,${bytes}`;
  if (IMAGE_MIME.has(mime)) return { kind: "image", url };
  if (AUDIO_MIME.has(mime)) return { kind: "audio", url };
  return undefined;
}

/** Only render bytes carried inline by the source. Provider URLs remain text. */
export function sourceMedia(json: string): SourceMedia[] {
  let root: unknown;
  try {
    root = JSON.parse(json);
  } catch {
    return [];
  }
  const media: SourceMedia[] = [];
  const pending: unknown[] = [root];
  for (let visited = 0; pending.length && visited < 4096 && media.length < 12; visited++) {
    const node = pending.pop();
    if (!node || typeof node !== "object") continue;
    if (Array.isArray(node)) {
      for (let i = node.length - 1; i >= 0; i--) {
        if (node[i] && typeof node[i] === "object") pending.push(node[i]);
      }
      continue;
    }
    const block = node as Record<string, unknown>;
    const url = block.image_url ?? block.url;
    const inline = typeof url === "string" && /^data:([^;,]+);base64,(.+)$/u.exec(url);
    const mime = inline ? inline[1] : text(block.mimeType ?? block.mediaType ?? block.media_type);
    const bytes = inline ? inline[2] : text(block.data ?? block.blob);
    const attachment = inlineSourceMedia(mime, bytes);
    if (attachment) media.push(attachment);
    const values = Object.values(block);
    for (let i = values.length - 1; i >= 0; i--) {
      if (values[i] && typeof values[i] === "object") pending.push(values[i]);
    }
  }
  return media;
}

export function decodeSourceText(data: string, mediaType?: string): string | undefined {
  const mime = mediaType?.split(";", 1)[0].trim().toLowerCase();
  if (mime && !mime.startsWith("text/") && !mime.endsWith("+json") && !mime.endsWith("+xml") &&
      !["application/json", "application/x-ndjson", "application/xml", "application/yaml", "application/toml"].includes(mime)) {
    return undefined;
  }
  try {
    const bytes = Uint8Array.from(atob(data), character => character.charCodeAt(0));
    return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    return undefined;
  }
}

export interface WireProvenance {
  kind?: string;
  method?: string;
  protocolVersion?: string;
  idJson?: string;
  additionalFieldsJson?: string;
  protocolVersionJsonBytes?: string;
  idJsonBytes?: string;
  additionalFieldsJsonBytes?: string;
  omittedProtocolVersionBytes?: string;
  omittedIdBytes?: string;
  omittedAdditionalFieldsBytes?: string;
}

export function wireFields(wire: WireProvenance): Array<[label: string, value: string]> {
  const fields: Array<[string, string]> = [];
  function add(label: string, value?: string) {
    if (value !== undefined) fields.push([label, value]);
  }
  function omitted(label: string, count?: string) {
    if (count && count !== "0") add(label, count);
  }
  add("Message kind", wire.kind);
  add("Method", wire.method);
  add("Protocol version", wire.protocolVersion === undefined ? undefined : JSON.stringify(wire.protocolVersion));
  add("Protocol version (base64)", wire.protocolVersionJsonBytes || undefined);
  omitted("Protocol version bytes omitted", wire.omittedProtocolVersionBytes);
  add("Request ID", wire.idJson);
  add("Request ID (base64)", wire.idJsonBytes || undefined);
  omitted("Request ID bytes omitted", wire.omittedIdBytes);
  add("Additional fields", wire.additionalFieldsJson || undefined);
  add("Additional fields (base64)", wire.additionalFieldsJsonBytes || undefined);
  omitted("Additional field bytes omitted", wire.omittedAdditionalFieldsBytes);
  return fields;
}

export type SessionStatus = "working" | "waiting" | "completed" | "failed" | "stopped";

export interface ConsoleRequest {
  id: string;
  question: string;
  status: "pending" | "answered" | "cancelled";
  answer?: string;
}

export interface ConsoleState {
  status?: SessionStatus;
  runId?: string;
  operationId?: string;
  requests: ConsoleRequest[];
  error?: string;
}

const STATUSES: readonly string[] = ["working", "waiting", "completed", "failed", "stopped"];

function text(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

/** Reads agent.state defensively: the state is empty until the backend publishes its first snapshot. */
export function readState(raw: unknown, workerStatus?: string): ConsoleState {
  const source = raw && typeof raw === "object" ? (raw as Record<string, unknown>) : {};
  const requests: ConsoleRequest[] = [];
  const reportedRequests = source.requests ?? source.pendingRequests;
  if (Array.isArray(reportedRequests)) {
    for (const item of reportedRequests) {
      if (!item || typeof item !== "object") continue;
      const record = item as Record<string, unknown>;
      const id = text(record.id);
      const status = record.status ?? "pending";
      if (!id || (status !== "pending" && status !== "answered" && status !== "cancelled")) continue;
      requests.push({
        id,
        question: text(record.question) ?? "",
        status,
        answer: text(record.answer),
      });
    }
  }
  const reported = text(source.status);
  const status = reported && STATUSES.includes(reported) ? reported : workerStatus;
  return {
    status: status && STATUSES.includes(status) ? (status as SessionStatus) : undefined,
    runId: text(source.runId ?? source.operationId),
    operationId: text(source.operationId),
    requests,
    error: text(source.error),
  };
}

// ---- Timeline ----

type ToolTermination = "failed" | "declined" | "cancelled" | "interrupted";

export type TimelineEntry =
  | { kind: "message"; id: string; speaker: "assistant" | "user"; text: string; sourceIds?: string[]; attachments?: ProviderPromptReference }
  | { kind: "diagnostic"; id: string; text: string }
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
      termination?: ToolTermination;
    };

/** Structural view of the AG-UI message shapes this console renders. */
interface WireMessage {
  id?: string;
  role?: string;
  content?: unknown;
  toolCalls?: Array<{ id?: string; function?: { name?: string; arguments?: string } }>;
  toolCallId?: string;
  error?: string;
  metadata?: { acp?: { source?: string; kind?: string; contentType?: string; turnId?: string; messageId?: string } };
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

function toolResult(message: WireMessage): { content: string; termination?: ToolTermination } {
  const body = contentText(message.content);
  const error = text(message.error)?.trim();
  if (!error) return { content: body };
  const hasError = `\n${body}\n`.includes(`\n${error}\n`);
  const content = hasError ? body : [error, body].filter(Boolean).join("\n");
  switch (error) {
    case "Tool declined.": return { content, termination: "declined" };
    case "Tool cancelled.": return { content, termination: "cancelled" };
    case "Tool interrupted.": return { content, termination: "interrupted" };
    default: return { content, termination: "failed" };
  }
}

/**
 * Turns agent.messages into the visible timeline: assistant and user text become conversation
 * entries, and every assistant tool call becomes its own activity entry joined to its tool-role result.
 */
export function buildTimeline(rawMessages: unknown): TimelineEntry[] {
  const messages: WireMessage[] = Array.isArray(rawMessages) ? (rawMessages as WireMessage[]) : [];
  const results = new Map<string, ReturnType<typeof toolResult>>();
  const callIDs = new Set(messages.flatMap(message => message?.toolCalls?.map(call => call.id) ?? []));
  for (const message of messages) {
    if (message?.role === "tool" && message.toolCallId) {
      results.set(message.toolCallId, toolResult(message));
    }
  }

  const entries: TimelineEntry[] = [];
  let reply: { turnId?: string; messageId?: string; row: { text: string; sourceIds: string[] } } | undefined;
  messages.forEach((message, index) => {
    const id = message?.id ?? `message-${index}`;
    const acp = message?.metadata?.acp;
    if (acp?.source === "live" && acp.kind === "agent_message_chunk" && (acp.contentType ?? "text") === "text" &&
        message.role === "assistant" && !message.toolCallId && !message.toolCalls?.length && typeof message.content === "string") {
      const turnId = text(acp.turnId), messageId = text(acp.messageId);
      if (reply && reply.turnId === turnId && reply.messageId === messageId) {
        reply.row.text += message.content;
        reply.row.sourceIds.push(id);
      } else {
        const row = { kind: "message" as const, id: id + "#chunks", speaker: "assistant" as const, text: message.content, sourceIds: [id] };
        entries.push(row);
        reply = { turnId, messageId, row };
      }
      return;
    }
    // A result already displayed beside its call is still a boundary in the source transcript.
    reply = undefined;
    if (!message) return;
    if (message.role === "user") {
      const body = contentText(message.content);
      const attachments = providerPromptReference(acp);
      if (body.trim() || attachments) entries.push({ kind: "message", id, speaker: "user", text: body,
        ...(attachments && { attachments }) });
      return;
    }
    if (message.role === "system" || (message.role === "tool" && !callIDs.has(message.toolCallId))) {
      const body = message.role === "tool" ? toolResult(message).content : contentText(message.content);
      if (body.trim()) entries.push({ kind: "diagnostic", id, text: body });
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
        termination: result?.termination,
      });
    });
  });
  return entries;
}

// ---- Scrollback ----

export type ScreenItem = TimelineEntry | { kind: "request"; id: string; request: ConsoleRequest };

/**
 * Places each Commander request in the scrollback. Requests live in state, not in messages, so a
 * request sits directly after a tool whose result carries its id or whose arguments identify it;
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
        (entry.result?.includes(request.id) || entry.raw.includes(request.id) ||
          (needle !== undefined && entry.raw.includes(needle))),
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
