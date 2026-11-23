// ATOMIC LEVEL: Pages.
// ConsolePage binds the real AG-UI session and the reply API to the terminal screen.
import React from "react";
import { NoticeLine, Scrollback, StartLine, StatusLine } from "./organisms";
import { TerminalScreen } from "./templates";
import { buildScrollback, statusPresentation } from "./model/contract";
import { useReply } from "./model/useReply";
import { useSession } from "./model/useSession";

export function ConsolePage() {
  const session = useSession();
  const reply = useReply();
  const { state, timeline, running, started } = session;

  const status = statusPresentation(state.status, started);
  const items = buildScrollback(timeline, state.requests);
  const pending = state.requests.filter((request) => request.status === "pending");

  // The native shell mirrors the page title in the window's title bar, as Terminal does.
  React.useEffect(() => {
    document.title = `claude — ${status.label}`;
  }, [status.label]);

  // Follow the end of the scrollback as output streams, tool results land and requests change.
  const last = timeline[timeline.length - 1];
  const lastSize = last
    ? last.kind === "message"
      ? last.text.length
      : (last.result ?? "").length + last.raw.length
    : 0;
  const followKey = [
    timeline.length,
    lastSize,
    state.requests.map((request) => `${request.id}:${request.status}`).join(","),
    state.status ?? "",
    state.error ?? "",
    session.launchError ?? "",
  ].join("|");

  const showRequest = () => {
    const prompt = document.querySelector<HTMLElement>('[data-request-pending="true"]');
    prompt?.scrollIntoView({ block: "center" });
    prompt?.querySelector<HTMLTextAreaElement>("textarea")?.focus();
  };

  const failed = Boolean(state.error || session.launchError);

  return (
    <TerminalScreen
      followKey={followKey}
      statusLine={
        <StatusLine
          status={status}
          pendingCount={pending.length}
          hasTools={timeline.some((entry) => entry.kind === "activity")}
          onShowRequest={showRequest}
        />
      }
    >
      {!started && <StartLine onStart={session.start} />}
      {started && items.length === 0 && !failed && <NoticeLine kind="waiting">starting session</NoticeLine>}
      <Scrollback
        items={items}
        running={running}
        focusRequestId={pending[0]?.id}
        phaseOf={reply.phaseOf}
        onReply={reply.send}
      />
      {state.error && <NoticeLine kind="error">{state.error}</NoticeLine>}
      {session.launchError && session.launchError !== state.error && (
        <NoticeLine kind="error">{session.launchError}</NoticeLine>
      )}
    </TerminalScreen>
  );
}

/** Shows a provider or agent failure in the terminal instead of a blank page. */
export class ConsoleErrorBoundary extends React.Component<
  { children: React.ReactNode },
  { message?: string }
> {
  state: { message?: string } = {};

  static getDerivedStateFromError(error: unknown) {
    return { message: error instanceof Error ? error.message : String(error) };
  }

  render() {
    if (this.state.message === undefined) return this.props.children;
    return (
      <TerminalScreen followKey="error" statusLine={null}>
        <NoticeLine kind="error">{`could not connect to the agent runtime\n${this.state.message}`}</NoticeLine>
      </TerminalScreen>
    );
  }
}
