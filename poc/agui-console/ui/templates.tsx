// ATOMIC LEVEL: Templates.
// Layout only: one full-width terminal screen. Scrollback fills the window from the native title
// bar down, with a compact status line pinned at the bottom. Content arrives as slots.
import React from "react";

export function TerminalScreen({
  statusLine,
  followKey,
  children,
}: {
  statusLine: React.ReactNode;
  /** Changes whenever the scrollback grows; the view follows it while the reader is at the end. */
  followKey: string;
  children: React.ReactNode;
}) {
  const scroll = React.useRef<HTMLElement>(null);
  const atEnd = React.useRef(true);

  React.useLayoutEffect(() => {
    const element = scroll.current;
    if (element && atEnd.current) element.scrollTop = element.scrollHeight;
  }, [followKey]);

  return (
    <div className="t-screen">
      <main
        ref={scroll}
        className="t-scroll"
        tabIndex={0}
        aria-label="Claude console"
        onScroll={(event) => {
          const element = event.currentTarget;
          atEnd.current = element.scrollHeight - element.scrollTop - element.clientHeight < 40;
        }}
      >
        {children}
      </main>
      <footer className="t-bar" aria-label="Session status">
        {statusLine}
      </footer>
    </div>
  );
}
