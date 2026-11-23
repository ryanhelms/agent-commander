import React from "react";
import { useAgent } from "@copilotkit/react-core/v2";
import { AGENT_ID, THREAD_ID, buildTimeline, readState } from "./contract";

// The one focused Claude session. Messages and state come from the AG-UI agent; the only thing
// this hook adds is whether Start session has been pressed in this page.

export function useSession() {
  const { agent } = useAgent({ agentId: AGENT_ID });
  const [launched, setLaunched] = React.useState(false);
  const [launchError, setLaunchError] = React.useState<string | undefined>();

  const start = React.useCallback(() => {
    if (launched) return;
    setLaunched(true);
    setLaunchError(undefined);
    agent.threadId = THREAD_ID;
    // runAgent settles when the run ends, so the session is live from the moment it is called.
    agent.runAgent({}).catch((error: unknown) => {
      setLaunchError(error instanceof Error ? error.message : "The session could not be started.");
    });
  }, [agent, launched]);

  const state = readState(agent.state);
  const timeline = buildTimeline(agent.messages);
  const running = Boolean(agent.isRunning);
  const started = launched || running || Boolean(state.runId) || timeline.length > 0;

  return { state, timeline, running, started, launched, launchError, start };
}
