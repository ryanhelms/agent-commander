import type { AgentSubscriber, HttpAgent, RunAgentResult } from '@ag-ui/client';

interface RequestOptions {
  signal?: AbortSignal;
}

interface ObserveOptions extends RequestOptions {
  /** False for a view which must never execute app tools. Requires Commander support. */
  dispatchTools?: boolean;
}

export interface CommanderUnconfirmedToolCall {
  id: string;
  name: string;
  arguments: Record<string, unknown>;
}

interface LocalConnection {
  socketPath: string;
  baseURL?: never;
  getAccessToken?: never;
}

interface HostedConnection {
  socketPath?: never;
  baseURL: string | URL;
  getAccessToken: () => string | Promise<string>;
}

export type CommanderConnection = (LocalConnection | HostedConnection) & RequestOptions & { workerId: string };

export class CommanderIncompleteRunError extends Error {
  readonly runId: string;
  constructor(runId: string);
}

export interface CommanderWorker {
  agent: HttpAgent;
  resume(options: ObserveOptions & { runId: string }, subscriber?: AgentSubscriber): Promise<RunAgentResult>;
  workerInfo(options?: RequestOptions): Promise<Response>;
  readHistory(options?: RequestOptions & {
    source?: 'provider' | 'journal' | 'live';
    view?: 'acp';
    cursor?: string;
    recordCursor?: string;
    turnId?: string;
    limit?: number;
  }): Promise<Response>;
  findOperation(options: RequestOptions & { runId: string }): Promise<Response>;
  observeRun(options: ObserveOptions & { runId: string }): Promise<Response>;
  observe(options: ObserveOptions & { operationId: string; runId: string }): Promise<Response>;
  reply(options: RequestOptions & {
    requestId: string;
    answer: string;
    generation?: number;
    idempotencyKey?: string;
  }): Promise<Response>;
  submitToolResult(options: RequestOptions & {
    operationId: string;
    message: { id: string; role: 'tool'; toolCallId: string; content: string; error?: string };
  }): Promise<Response>;
}

export function connectCommanderWorker(options: CommanderConnection): CommanderWorker;
