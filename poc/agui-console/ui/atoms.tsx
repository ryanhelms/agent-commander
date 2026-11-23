// ATOMIC LEVEL: Atoms.
// Single-purpose terminal elements. They receive values and emit events; none know about sessions.
import React from "react";
import type { Ink as InkRole } from "./model/contract";

/** Colored run of text. Color never carries meaning alone: pair it with a glyph or a word. */
export function Ink({
  ink,
  bold = false,
  children,
}: {
  ink?: InkRole;
  bold?: boolean;
  children: React.ReactNode;
}) {
  return (
    <span className="a-ink" data-ink={ink} data-bold={bold}>
      {children}
    </span>
  );
}

/** A one-cell status or gutter mark. Decorative: the adjacent text states the same thing. */
export function Glyph({ char, ink, pulse = false }: { char: string; ink?: InkRole; pulse?: boolean }) {
  return (
    <span className="a-glyph" data-ink={ink} data-pulse={pulse} aria-hidden="true">
      {char}
    </span>
  );
}

type ButtonProps = Omit<React.ButtonHTMLAttributes<HTMLButtonElement>, "children"> & {
  label: string;
  ink?: InkRole;
  /** Shown inside the brackets, for a key that really triggers this button. */
  keyHint?: string;
};

/** Terminal-styled action: `[ label ]`. A real button, reachable with Tab and activated with Return or Space. */
export const TermButton = React.forwardRef<HTMLButtonElement, ButtonProps>(function TermButton(
  { label, ink = "bright", keyHint, type = "button", ...rest },
  ref,
) {
  return (
    <button ref={ref} className="a-button" data-ink={ink} type={type} {...rest}>
      <span aria-hidden="true">[ </span>
      <span>{label}</span>
      {keyHint && <span aria-hidden="true">{` ${keyHint}`}</span>}
      <span aria-hidden="true"> ]</span>
    </button>
  );
});

export function KeyHint({ keys, keyLabel, action }: { keys: string; keyLabel?: string; action: string }) {
  return (
    <span className="a-hint">
      <kbd aria-label={keyLabel}>{keys}</kbd>
      <span>{action}</span>
    </span>
  );
}

/** Literal monospaced text: spaces and newlines are kept and long lines wrap. */
export function Pre({ children, ink }: { children: string; ink?: InkRole }) {
  return (
    <pre className="a-pre" data-ink={ink}>
      {children}
    </pre>
  );
}

/** A textarea drawn as the text after a prompt mark. It grows with its content. */
export const PromptInput = React.forwardRef<
  HTMLTextAreaElement,
  React.TextareaHTMLAttributes<HTMLTextAreaElement>
>(function PromptInput({ value, ...rest }, ref) {
  const rows = Math.min(16, Math.max(1, String(value ?? "").split("\n").length));
  return (
    <textarea
      ref={ref}
      className="a-prompt-input"
      rows={rows}
      value={value}
      spellCheck={false}
      autoCapitalize="off"
      autoCorrect="off"
      {...rest}
    />
  );
});
