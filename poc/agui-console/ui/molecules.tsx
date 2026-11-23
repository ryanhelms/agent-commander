// ATOMIC LEVEL: Molecules.
// Terminal lines and rows, each with one job.
import React from "react";
import { Glyph, Ink, Pre, PromptInput, TermButton } from "./atoms";
import type { Ink as InkRole, StatusView } from "./model/contract";
import { parseMarkdown } from "./model/markdown";

/** A scrollback entry: a mark in the gutter and content beside it. */
export function Line({
  glyph,
  ink,
  pulse,
  children,
}: {
  glyph: string;
  ink?: InkRole;
  pulse?: boolean;
  children: React.ReactNode;
}) {
  return (
    <div className="m-line">
      <Glyph char={glyph} ink={ink} pulse={pulse} />
      <div>{children}</div>
    </div>
  );
}

/** Assistant output as terminal lines, with the small Markdown subset applied. */
export function Output({ text }: { text: string }) {
  const blocks = React.useMemo(() => parseMarkdown(text), [text]);
  return (
    <div className="m-output">
      {blocks.map((block, index) =>
        block.kind === "code" ? (
          <pre key={index} className="m-code" aria-label={block.lang ? `${block.lang} code` : "code"}>
            {block.text}
          </pre>
        ) : (
          <div key={index} className="m-output-line" data-heading={block.heading}>
            {block.spans.map((span, spanIndex) =>
              span.kind === "code" ? (
                <code key={spanIndex}>{span.text}</code>
              ) : span.kind === "bold" ? (
                <b key={spanIndex}>{span.text}</b>
              ) : (
                <React.Fragment key={spanIndex}>{span.text}</React.Fragment>
              ),
            )}
          </div>
        ),
      )}
    </div>
  );
}

export interface ToolState {
  label: string;
  glyph: string;
  ink: InkRole;
}

/**
 * One tool call as a collapsible terminal row. The row is a button: ▸ closed, ▾ open. Opening it
 * shows the full command, the arguments and the result, all selectable.
 */
export function ToolRow({
  id,
  name,
  command,
  input,
  result,
  state,
}: {
  id: string;
  name: string;
  command?: string;
  input: string;
  result?: string;
  state: ToolState;
}) {
  const [open, setOpen] = React.useState(false);
  const detailId = `tool-${id}-detail`;
  const summary = command ? `$ ${command}` : input.replace(/\s+/g, " ");
  const hasDetail = Boolean(command || input || result);

  return (
    <div>
      <button
        type="button"
        className="m-tool-row"
        aria-expanded={open}
        aria-controls={detailId}
        onClick={() => setOpen((value) => !value)}
      >
        <Glyph char={open ? "▾" : "▸"} ink="dim" />
        <Ink ink="violet" bold>
          {name}
        </Ink>
        <Ink ink={command ? "cyan" : "dim"}>{open ? "" : summary}</Ink>
        <Ink ink={state.ink}>
          <span aria-hidden="true">{state.glyph} </span>
          {state.label}
        </Ink>
      </button>
      <div id={detailId} className="m-tool-detail" hidden={!open}>
        {command && <Pre ink="cyan">{`$ ${command}`}</Pre>}
        {input && (
          <>
            <Ink ink="dim">args</Ink>
            <Pre>{input}</Pre>
          </>
        )}
        {result !== undefined && result !== "" && (
          <>
            <Ink ink="dim">result</Ink>
            <Pre ink={state.ink === "red" ? "red" : undefined}>{result}</Pre>
          </>
        )}
        {!hasDetail && <Ink ink="dim">no arguments or output</Ink>}
      </div>
    </div>
  );
}

export function StatusSegment({ status }: { status: StatusView }) {
  return (
    <span className="m-status" data-ink={status.ink} role="status" aria-label={`Session ${status.label}`}>
      <Glyph char={status.glyph} pulse={status.live} />
      <span>{status.label}</span>
    </span>
  );
}

/**
 * The reply prompt: `❯` followed by a native multiline field. Return sends, Shift-Return or
 * Option-Return adds a line, Command-Return also sends. Pasted text keeps its newlines and the
 * text is sent exactly as typed.
 */
export function PromptLine({
  label,
  value,
  onChange,
  onSend,
  busy,
  locked,
  autoFocus,
}: {
  label: string;
  value: string;
  onChange: (value: string) => void;
  onSend: () => void;
  busy: boolean;
  locked: boolean;
  autoFocus: boolean;
}) {
  const field = React.useRef<HTMLTextAreaElement>(null);
  const canSend = !busy && !locked && value.trim().length > 0;

  React.useEffect(() => {
    if (autoFocus) field.current?.focus();
    // Focus once, when the prompt first appears.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  return (
    <form
      onSubmit={(event) => {
        event.preventDefault();
        if (canSend) onSend();
      }}
    >
      <div className="m-prompt-row">
        <Glyph char="❯" ink="amber" />
        <PromptInput
          ref={field}
          aria-label={label}
          aria-keyshortcuts="Enter Meta+Enter"
          placeholder="type a reply"
          value={value}
          disabled={busy || locked}
          onChange={(event) => onChange(event.target.value)}
          onKeyDown={(event) => {
            if (event.key !== "Enter" || event.nativeEvent.isComposing) return;
            if (event.shiftKey || event.altKey) return; // newline
            event.preventDefault();
            if (canSend) onSend();
          }}
        />
      </div>
      <div className="m-prompt-actions">
        <TermButton
          type="submit"
          ink="amber"
          label={busy ? "sending…" : "send"}
          keyHint={busy ? undefined : "↩"}
          disabled={!canSend}
        />
      </div>
    </form>
  );
}
