import React from "react";
import { useAgent } from "@copilotkit/react-core/v2";
import { AGENT_ID, THREAD_ID, buildTimeline, readState } from "./contract";

type Configuration =
  | { mode: "demo" }
  | { mode: "worker"; workerId: string; client?: string; generation?: number; status?: string; nativeHistory: boolean };

async function loadConfiguration(signal?: AbortSignal): Promise<Configuration> {
  const response = await fetch("/console-config", { signal });
  const payload = await response.json();
  if (!response.ok) throw new Error(payload.error ?? "Could not open the console.");
  return payload;
}

function tabRunId(workerId: string, runId?: string | null): string | null {
  try {
    const key = `commander.lastRun.${workerId}`;
    if (runId === undefined) return sessionStorage.getItem(key);
    if (runId === null) sessionStorage.removeItem(key);
    else sessionStorage.setItem(key, runId);
    return runId;
  } catch {
    return null;
  }
}

export function useSession() {
  const { agent, isReady } = useAgent({ agentId: AGENT_ID });
  const [launched, setLaunched] = React.useState(false);
  const [launchError, setLaunchError] = React.useState<string | undefined>();
  const [configuration, setConfiguration] = React.useState<Configuration>();
  const [submitting, setSubmitting] = React.useState(false);
  const [reopening, setReopening] = React.useState(false);
  const busy = React.useRef(false);
  const attempt = React.useRef<{ text: string; generation: number; runId: string } | undefined>(undefined);
  const workerId = configuration?.mode === "worker" ? configuration.workerId : undefined;

  React.useEffect(() => {
    const controller = new AbortController();
    loadConfiguration(controller.signal).then(setConfiguration).catch(error => {
      if (!controller.signal.aborted) setLaunchError(error.message);
    });
    return () => controller.abort();
  }, []);

  React.useEffect(() => {
    if (!workerId || !isReady) return;
    const runId = tabRunId(workerId);
    if (!runId) return;
    let cancelled = false;
    busy.current = true;
    setReopening(true);
    agent.threadId = workerId;
    let terminal = false;
    void agent.connectAgent({ runId, forwardedProps: { commanderObserve: true } }, {
      onRunFinishedEvent() { terminal = true; },
      onRunErrorEvent({ event }) {
        terminal = true;
        if (!cancelled) setLaunchError(event.message);
      },
    }).then(() => {
      if (!cancelled && !terminal) setLaunchError("The connection ended before Commander confirmed the outcome. Reload to reopen this follow-up.");
    }).catch((error: unknown) => {
      if (cancelled) return;
      if (error && typeof error === "object" && "status" in error && error.status === 404) {
        tabRunId(workerId, null);
        setLaunchError("Commander could not find a receipt for this follow-up.");
      } else {
        setLaunchError(error instanceof Error ? error.message : "The follow-up could not be reopened.");
      }
    }).finally(() => {
      if (cancelled) return;
      busy.current = false;
      setReopening(false);
    });
    return () => {
      cancelled = true;
      busy.current = false;
      setReopening(false);
      void agent.detachActiveRun();
    };
  }, [agent, isReady, workerId]);

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

  const sendPrompt = React.useCallback(async (text: string) => {
    if (!isReady || configuration?.mode !== "worker" || configuration.status === "stopped" || busy.current || !text.trim()) return false;
    busy.current = true;
    setSubmitting(true);
    setLaunchError(undefined);
    try {
      const current = await loadConfiguration();
      if (current.mode !== "worker" || current.generation === undefined) {
        throw new Error("Take input control in Commander before sending a follow-up.");
      }
      let submission = attempt.current;
      if (!submission || submission.text !== text) {
        submission = { text, generation: current.generation, runId: crypto.randomUUID() };
        attempt.current = submission;
      }
      tabRunId(current.workerId, submission.runId);
      agent.threadId = current.workerId;
      if (agent.messages.at(-1)?.id !== submission.runId) {
        agent.setMessages(agent.messages.filter(message => message.id !== submission.runId));
        agent.addMessage({ id: submission.runId, role: "user", content: text });
      }
      let terminal = false;
      let runError: string | undefined;
      await agent.runAgent({ runId: submission.runId, forwardedProps: { generation: submission.generation } }, {
        onRunFinishedEvent() { terminal = true; },
        onRunErrorEvent({ event }) { runError = event.message; },
      });
      if (runError !== undefined) throw new Error(runError);
      if (!terminal) throw new Error("The connection ended before Commander confirmed the outcome. Reload to reopen this follow-up.");
      attempt.current = undefined;
      return true;
    } catch (error) {
      setLaunchError(error instanceof Error ? error.message : "The follow-up could not be sent.");
      return false;
    } finally {
      busy.current = false;
      setSubmitting(false);
    }
  }, [agent, configuration, isReady]);

  const state = readState(agent.state, configuration?.mode === "worker" ? configuration.status : undefined);
  const timeline = buildTimeline(agent.messages);
  const running = Boolean(agent.isRunning);
  const started = launched || running || Boolean(state.runId) || timeline.length > 0;

  return { state, timeline, running, started, launched, launchError, start, configuration, sendPrompt, submitting, reopening };
}
