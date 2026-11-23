// ATOMIC LEVEL: Organisms.
// Sections of the terminal screen. They receive session values and emit targeted actions.
import React from "react";
import { Ink, KeyHint, Pre, TermButton } from "./atoms";
import { Line, Output, PromptLine, StatusSegment, ToolRow } from "./molecules";
import type { ToolState } from "./molecules";
import type { ConsoleRequest, ScreenItem, StatusView } from "./model/contract";
import type { ReplyPhase } from "./model/useReply";

function toolState(result: string | undefined, failed: boolean, running: boolean): ToolState {
  if (failed) return { label: "failed", glyph: "✗", ink: "red" };
  if (result !== undefined) return { label: "done", glyph: "✓", ink: "green" };
  if (running) return { label: "running", glyph: "…", ink: "amber" };
  return { label: "no result", glyph: "–", ink: "dim" };
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

  if (request.status === "answered") {
    return (
      <section className="o-prompt" data-resolved="true" aria-labelledby={titleId}>
        <Line glyph="✓" ink="green">
          <Ink ink="green">answered</Ink> <Ink ink="dim">{request.id}</Ink>
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
  running,
  focusRequestId,
  phaseOf,
  onReply,
}: {
  items: ScreenItem[];
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
                claude
              </Ink>
              <Output text={item.text} />
            </Line>
          )}
          {item.kind === "message" && item.speaker === "user" && (
            <Line glyph="❯" ink="dim">
              <Pre ink="bright">{item.text}</Pre>
            </Line>
          )}
          {item.kind === "activity" && (
            <ToolRow
              id={item.id}
              name={item.name}
              command={item.command}
              input={item.input}
              result={item.result}
              state={toolState(item.result, item.failed, running)}
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
