// ATOMIC LEVEL: Organisms.
// Sections of the terminal screen. They receive session values and emit targeted actions.
import React from "react";
import { Ink, KeyHint, Pre, TermButton } from "./atoms";
import { Line, Output, PromptLine, StatusSegment, ToolRow } from "./molecules";
import type { ToolState } from "./molecules";
import type { ConsoleRequest, ScreenItem, StatusView, TimelineEntry, WireProvenance } from "./model/contract";
import { decodeSourceText, inlineSourceMedia, sourceMedia, wireFields } from "./model/contract";
import { providerPromptMedia, selectedProviderMedia, type ProviderMedia, type ProviderPromptReference } from "../connector/provider-media.mjs";
import type { ReplyPhase } from "./model/useReply";

function toolState(item: Extract<TimelineEntry, { kind: "activity" }>, running: boolean): ToolState {
  if (item.termination === "failed") return { label: "failed", glyph: "✗", ink: "red" };
  if (item.termination) return { label: item.termination, glyph: "!", ink: "amber" };
  if (item.result !== undefined) return { label: "done", glyph: "✓", ink: "green" };
  if (running) return { label: "running", glyph: "…", ink: "amber" };
  return { label: "no result", glyph: "–", ink: "dim" };
}

type SourcePayload = { type: string; data: string; mediaType?: string };

type HistoryRecord = {
  cursor?: string;
  turnId?: string;
  session?: { harnessInstance?: string; sessionId?: string };
  gap?: { reason: string };
  extension?: SourcePayload;
  sourceRecord?: SourcePayload;
  sourceCursor?: string;
  wireProvenance?: WireProvenance;
  text?: { speaker?: string; text?: string };
  tool?: { name?: string; phase?: string; summary?: string; callId?: string };
  input?: { prompt?: string; choices?: Array<{ label?: string; id?: string }> };
  turnEnded?: { reason?: string };
};

function SourceDisclosure({ label, children }: { label: React.ReactNode; children: () => React.ReactNode }) {
  const [open, setOpen] = React.useState(false);
  return <details onToggle={event => {
    if (event.target === event.currentTarget) setOpen(event.currentTarget.open);
  }}>
    <summary>{label}</summary>
    {open && children()}
  </details>;
}

type HistoryPage = {
  observations?: HistoryRecord[];
  nextCursor?: string;
  error?: string;
};

function SourcePreviews({ media }: { media: ReturnType<typeof sourceMedia> }) {
  return <>{media.map(({ kind, url }, index) =>
    kind === "image" ? <img key={index} src={url} alt="Image from the session source" /> :
      <audio key={index} controls preload="none" src={url} aria-label="Audio from the session source" />,
  )}</>;
}

function ProviderPayload({ payload, showPreviews = true }: { payload: SourcePayload; showPreviews?: boolean }) {
  const decoded = decodeSourceText(payload.data, payload.mediaType);
  const inline = inlineSourceMedia(payload.mediaType, payload.data);
  const media = !showPreviews ? [] : inline ? [inline] : decoded !== undefined ? sourceMedia(decoded) : [];
  return <>
    <SourcePreviews media={media}/>
    {payload.mediaType && <Ink ink="dim">{payload.mediaType}</Ink>}
    {decoded === undefined && <Ink ink="dim">Base64</Ink>}
    <Pre ink="bright">{decoded ?? payload.data}</Pre>
  </>;
}

function MediaList({ items }: { items: ProviderMedia[] }) {
  return <ol>{items.map((item, index) => <li key={index}>
    <SourceDisclosure label={`Attachment ${index + 1} · ${item.mime || item.kind}`}>{() =>
      item.preview ? <SourcePreviews media={[{ kind: item.kind, url: item.preview }]} /> :
        <Pre>{item.reference ?? "No supported inline preview is available."}</Pre>
    }</SourceDisclosure>
  </li>)}</ol>;
}

function SelectedMedia({ reference }: { reference: ProviderPromptReference }) {
  const [items, setItems] = React.useState<ProviderMedia[]>();
  const [error, setError] = React.useState<string>();
  React.useEffect(() => {
    const controller = new AbortController();
    const query = new URLSearchParams({ recordCursor: reference.cursor });
    if (reference.pageCursor) query.set("cursor", reference.pageCursor);
    void (async () => {
      try {
        const response = await fetch("/provider-history?" + query, { signal: controller.signal });
        const page = await response.json();
        if (!response.ok) throw new Error(page.error ?? "Provider history is unavailable.");
        const media = selectedProviderMedia(page, reference);
        if (!controller.signal.aborted) setItems(media);
      } catch (failure) {
        if (!controller.signal.aborted) setError(failure instanceof Error ? failure.message : "Could not open the attachment.");
      }
    })();
    return () => controller.abort();
  }, [reference.cursor, reference.pageCursor, reference.itemCount]);
  return error ? <NoticeLine kind="error">{error}</NoticeLine> :
    items ? <MediaList items={items} /> : <NoticeLine kind="waiting">Loading attachments</NoticeLine>;
}

function ProviderOriginal({ record, pageCursor }: { record: HistoryRecord; pageCursor?: string }) {
  if (!record.sourceRecord) return null;
  const items = providerPromptMedia(record);
  return <>
    {items.length > 0 && record.cursor && <SourceDisclosure label={`Open attachments (${items.length})`}>
      {() => <SelectedMedia reference={{ cursor: record.cursor!, pageCursor, itemCount: items.length }} />}
    </SourceDisclosure>}
    <ProviderPayload payload={record.sourceRecord} showPreviews={!items.length}/>
  </>;
}

function SourceRecord({ record, pageCursor }: { record: HistoryRecord; pageCursor?: string }) {
  const { extension, gap, text, tool, input, turnEnded, wireProvenance } = record;
  const speaker = text?.speaker?.toLowerCase().replace(/^speaker_/, "");
  const title = gap?.reason || extension?.type || (text && (speaker ? `${speaker} message` : "Message")) ||
    (tool && [tool.name || tool.callId || "Tool", tool.phase].filter(Boolean).join(" · ")) ||
    (input && "Historical request") || (turnEnded && "Turn ended") || "Source record";
  const detail = text?.text ?? tool?.summary ?? input?.prompt ?? turnEnded?.reason;
  return (
    <SourceDisclosure label={gap ? <Ink ink="amber">{title}</Ink> : title}>
      {() => <>
        {detail && <Pre ink="bright">{detail}</Pre>}
        {input?.choices?.length ? <Pre>{input.choices.map(choice => [choice.label, choice.id].filter(Boolean).join(" · ")).join("\n")}</Pre> : null}
        {extension && <ProviderPayload payload={extension} />}
        {record.sourceRecord && <ProviderOriginal record={record} pageCursor={pageCursor} />}
        {wireProvenance && <SourceDisclosure label="JSON-RPC envelope">
          {() => <>
            {wireProvenance.additionalFieldsJson && <SourcePreviews media={sourceMedia(wireProvenance.additionalFieldsJson)} />}
            <dl className="o-wire-fields">
              {wireFields(wireProvenance).map(([label, value]) => <React.Fragment key={label}>
                <dt>{label}</dt>
                <dd><Pre>{value}</Pre></dd>
              </React.Fragment>)}
            </dl>
          </>}
        </SourceDisclosure>}
        <SourceDisclosure label="Original record">
          {() => <Pre>{JSON.stringify(record, null, 2)}</Pre>}
        </SourceDisclosure>
      </>}
    </SourceDisclosure>
  );
}

const sessionSources = {
  provider: { label: "Provider history", path: "/provider-history" },
  journal: { label: "Session journal", path: "/session-journal" },
  live: { label: "Live ACP source", path: "/live-acp-source" },
};

export function SessionSource({ source, turnId }: { source: keyof typeof sessionSources; turnId?: string }) {
  const { label: sourceLabel, path } = sessionSources[source];
  const label = turnId ? "This turn’s ACP source" : sourceLabel;
  const [page, setPage] = React.useState<HistoryPage>();
  const [error, setError] = React.useState<{ message: string; cursor: string; previous: string[] }>();
  const [loading, setLoading] = React.useState(false);
  const [previous, setPrevious] = React.useState<string[]>([]);
  const [cursor, setCursor] = React.useState("");
  const pending = React.useRef<AbortController | undefined>(undefined);

  React.useEffect(() => () => pending.current?.abort(), []);

  const load = async (next: string, back: string[]) => {
    if (pending.current) return;
    const request = new AbortController();
    pending.current = request;
    setLoading(true);
    setError(undefined);
    try {
      const query = new URLSearchParams({ cursor: next });
      if (turnId) query.set("turnId", turnId);
      const response = await fetch(`${path}?${query}`, { signal: request.signal });
      const payload: HistoryPage = await response.json();
      if (!response.ok) throw new Error(payload.error || `${label} is unavailable.`);
      setCursor(next);
      setPage(payload);
      setPrevious(back);
    } catch (failure) {
      if (!request.signal.aborted) setError({
        message: failure instanceof Error ? failure.message : `${label} is unavailable.`,
        cursor: next, previous: back,
      });
    } finally {
      pending.current = undefined;
      if (!request.signal.aborted) setLoading(false);
    }
  };

  return (
    <details className="o-journal" onToggle={event => {
      if (event.target === event.currentTarget && event.currentTarget.open && (!page || source === "live") && !error) void load("", []);
    }}>
      <summary>{label}</summary>
      {loading && <NoticeLine kind="waiting">{`Loading ${label.toLowerCase()}`}</NoticeLine>}
      {error && <NoticeLine kind="error">{error.message}</NoticeLine>}
      {error && <TermButton label="Retry" onClick={() => void load(error.cursor, error.previous)} />}
      {source !== "journal" && page && !loading && !error && <TermButton label="Refresh source" onClick={() => void load("", [])} />}
      {page?.observations?.length === 0 && <Line glyph="·" ink="dim">No records on this page.</Line>}
      {page?.observations?.map((record, index) => {
        const id = `${record.cursor ?? ""}:${index}`;
        return <SourceRecord key={id} record={record} pageCursor={cursor || undefined} />;
      })}
      {previous.length > 0 &&
        <TermButton label="Previous records" disabled={loading} onClick={() => void load(previous.at(-1)!, previous.slice(0, -1))} />}
      {page?.nextCursor &&
        <TermButton label="More records" disabled={loading} onClick={() => void load(page.nextCursor!, [...previous, cursor])} />}
    </details>
  );
}

/** A Commander request in the scrollback: a live prompt while pending, a record once answered. */
export function RequestPrompt({
  request,
  phase,
  onSend,
  autoFocus,
}: {
  request: ConsoleRequest;
  phase: ReplyPhase;
  onSend: (answer: string) => void;
  autoFocus: boolean;
}) {
  const [draft, setDraft] = React.useState("");
  const titleId = `request-${request.id}-question`;

  if (request.status !== "pending") {
    const answered = request.status === "answered";
    return (
      <section className="o-prompt" data-resolved="true" aria-labelledby={titleId}>
        <Line glyph={answered ? "✓" : "–"} ink={answered ? "green" : "dim"}>
          <Ink ink={answered ? "green" : "dim"}>{request.status}</Ink> <Ink ink="dim">{request.id}</Ink>
          <h2 id={titleId}>{request.question}</h2>
        </Line>
        {request.answer !== undefined && (
          <Line glyph="❯" ink="dim">
            <Pre ink="bright">{request.answer}</Pre>
          </Line>
        )}
      </section>
    );
  }

  return (
    <section className="o-prompt" aria-labelledby={titleId} data-request-pending="true">
      <Line glyph="?" ink="amber" pulse>
        <Ink ink="amber" bold>
          input needed
        </Ink>{" "}
        <Ink ink="dim">{request.id}</Ink>
        <h2 id={titleId}>{request.question}</h2>
      </Line>
      <PromptLine
        label={`Reply to ${request.id}`}
        value={draft}
        onChange={setDraft}
        onSend={() => onSend(draft)}
        busy={phase.phase === "sending"}
        locked={phase.phase === "sent"}
        autoFocus={autoFocus}
      />
      {phase.phase === "sent" && (
        <div role="status">
          <Line glyph="✓" ink="green">
            <Ink ink="green">reply delivered</Ink> <Ink ink="dim">waiting for the session to confirm</Ink>
          </Line>
        </div>
      )}
      {phase.phase === "error" && (
        <div role="alert">
          <Line glyph="✗" ink="red">
            <Ink ink="red">{phase.message}</Ink> <Ink ink="dim">your reply is still in the prompt</Ink>
          </Line>
        </div>
      )}
    </section>
  );
}

export function Scrollback({
  items,
  clientName,
  running,
  focusRequestId,
  phaseOf,
  onReply,
}: {
  items: ScreenItem[];
  clientName: string;
  running: boolean;
  focusRequestId?: string;
  phaseOf: (requestId: string) => ReplyPhase;
  onReply: (requestId: string, answer: string) => void;
}) {
  if (items.length === 0) return null;
  return (
    <ol className="o-scrollback" aria-label="Session transcript">
      {items.map((item) => (
        <li key={item.id} data-kind={item.kind}>
          {item.kind === "message" && item.speaker === "assistant" && (
            <Line glyph="●" ink="cyan">
              <Ink ink="cyan" bold>
                {clientName}
              </Ink>
              <Output text={item.text} />
            </Line>
          )}
          {item.kind === "message" && item.speaker === "user" && (
            <Line glyph="❯" ink="dim">
              <Pre ink="bright">{item.text}</Pre>
              {item.attachments && <SourceDisclosure label={`Open attachments (${item.attachments.itemCount})`}>
                {() => <SelectedMedia reference={item.attachments!} />}
              </SourceDisclosure>}
            </Line>
          )}
          {item.kind === "diagnostic" && (
            <Line glyph="·" ink="dim">
              <Pre ink="dim">{item.text}</Pre>
            </Line>
          )}
          {item.kind === "activity" && (
            <ToolRow
              id={item.id}
              name={item.name}
              command={item.command}
              input={item.input}
              result={item.result}
              state={toolState(item, running)}
            />
          )}
          {item.kind === "request" && (
            <RequestPrompt
              request={item.request}
              phase={phaseOf(item.request.id)}
              onSend={(answer) => onReply(item.request.id, answer)}
              autoFocus={item.request.id === focusRequestId}
            />
          )}
        </li>
      ))}
    </ol>
  );
}

export function FollowUpPrompt({ busy, locked, send }: { busy: boolean; locked: boolean; send: (text: string) => Promise<boolean> }) {
  const [draft, setDraft] = React.useState("");
  return (
    <PromptLine
      label="Follow-up to worker"
      value={draft}
      onChange={setDraft}
      onSend={() => {
        void send(draft).then(accepted => {
          if (accepted) setDraft(current => current === draft ? "" : current);
        });
      }}
      busy={busy}
      locked={locked}
      autoFocus={false}
    />
  );
}

/** Shown before the session exists. The button takes focus, so Return starts the session. */
export function StartLine({ onStart }: { onStart: () => void }) {
  const button = React.useRef<HTMLButtonElement>(null);
  React.useEffect(() => button.current?.focus(), []);
  return (
    <Line glyph="○" ink="dim">
      <Ink ink="dim">no session yet. one focused claude session runs per launch.</Ink>
      <div>
        <TermButton ref={button} label="start session" ink="green" keyHint="↩" onClick={onStart} />
      </div>
    </Line>
  );
}

export function NoticeLine({ kind, children }: { kind: "waiting" | "error"; children: string }) {
  return kind === "error" ? (
    <div role="alert">
      <Line glyph="✗" ink="red">
        <Ink ink="red" bold>
          error
        </Ink>
        <Pre ink="red">{children}</Pre>
      </Line>
    </div>
  ) : (
    <div role="status">
      <Line glyph="…" ink="dim" pulse>
        <Ink ink="dim">{children}</Ink>
      </Line>
    </div>
  );
}

/** Session status and controls that are relevant to the current view. */
export function StatusLine({
  status,
  pendingCount,
  hasTools,
  onShowRequest,
}: {
  status: StatusView;
  pendingCount: number;
  hasTools: boolean;
  onShowRequest: () => void;
}) {
  const hasRequest = pendingCount > 0;

  return (
    <>
      <div className="o-status">
        <StatusSegment status={status} />
        {hasRequest && (
          <TermButton
            ink="amber"
            label={pendingCount === 1 ? "view request" : `view ${pendingCount} requests`}
            onClick={onShowRequest}
          />
        )}
      </div>
      {(hasRequest || hasTools) && (
        <div className="o-hints" role="group" aria-label="Keyboard shortcuts">
          {/* Shown while keyboard focus is on a tool row. */}
          {hasTools && (
            <span data-when="tool-focus">
              <KeyHint keys="space" action="toggle details" />
            </span>
          )}
          {/* Shown while a request is waiting; the prompt takes focus when it appears. */}
          {hasRequest && (
            <>
              <KeyHint keys="↵" keyLabel="Return" action="send" />
              <KeyHint keys="⇧↵" keyLabel="Shift Return" action="new line" />
            </>
          )}
        </div>
      )}
    </>
  );
}
