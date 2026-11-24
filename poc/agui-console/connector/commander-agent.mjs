import { request } from 'node:http';
import { Readable } from 'node:stream';
import { HttpAgent, runHttpRequest, transformHttpEventStream } from '@ag-ui/client';
import { tap } from 'rxjs';

/** Commander may still be running after a successful HTTP response ends. */
export class CommanderIncompleteRunError extends Error {
  constructor(runId) {
    super(`Commander stream ended before a terminal event for run ${runId}. Reconnect using the same run ID.`);
    this.name = 'CommanderIncompleteRunError';
    this.runId = runId;
  }
}

function requireTerminal(events, input) {
  let terminal = false;
  return events.pipe(tap({
    next(event) {
      if (event.type === 'RUN_FINISHED' || event.type === 'RUN_ERROR') terminal = true;
    },
    // Explicit detach unsubscribes from this operator. Only transport EOF completes it.
    complete() {
      if (!terminal) throw new CommanderIncompleteRunError(input.runId);
    },
  }));
}

function socketRequest(socketPath, path, { method = 'GET', headers, body, signal } = {}) {
  return new Promise((resolve, reject) => {
    const req = request({
      socketPath,
      path,
      method,
      headers: Object.fromEntries(new Headers(headers)),
      signal,
    }, response => {
      const headers = new Headers();
      for (const [index, name] of response.rawHeaders.entries()) {
        if (index % 2 === 0) headers.append(name, response.rawHeaders[index + 1]);
      }
      resolve(new Response(Readable.toWeb(response), { status: response.statusCode, headers }));
    });
    req.on('error', reject);
    req.end(body ?? undefined);
  });
}

/** Bind a server-side CopilotKit runtime or AG-UI consumer to one Commander worker. */
export function connectCommanderWorker({ socketPath, baseURL, getAccessToken, workerId, signal: lifetime }) {
  if (!workerId || Boolean(socketPath) === Boolean(baseURL)) {
    throw new TypeError('Provide a worker ID and either a socket path or an HTTPS origin.');
  }
  const origin = baseURL ? new URL(baseURL) : new URL('http://localhost');
  if (baseURL && (origin.protocol !== 'https:' || origin.username || origin.password ||
      origin.pathname !== '/' || origin.search || origin.hash || typeof getAccessToken !== 'function')) {
    throw new TypeError('Hosted Commander requires an HTTPS origin and an access token provider.');
  }
  const transport = socketPath
    ? (path, options) => socketRequest(socketPath, path, options)
    : async (path, options) => {
        const token = await getAccessToken();
        if (typeof token !== 'string' || !token || /\s/u.test(token)) {
          throw new Error('Commander needs a valid access token.');
        }
        const headers = new Headers(options?.headers);
        headers.set('Authorization', 'Bearer ' + token);
        return fetch(new URL(path, origin), { ...options, headers, redirect: 'error' });
      };
  const send = (path, options = {}) => {
    const signal = lifetime && options.signal ? AbortSignal.any([lifetime, options.signal]) : lifetime ?? options.signal;
    return transport(path, { ...options, signal });
  };
  const worker = encodeURIComponent(workerId);
  const workerPath = `/v1/ag-ui/workers/${worker}`;
  const runPath = workerPath + '/run?projection=incremental';
  const findOperation = ({ runId, signal }) => {
    const query = new URLSearchParams({ runId });
    return send(`${workerPath}/operations?${query}`, { signal });
  };
  const observe = async ({ operationId, runId, signal, dispatchTools = true }) => {
    const operation = encodeURIComponent(operationId);
    const query = new URLSearchParams({ runId, projection: 'incremental' });
    if (!dispatchTools) query.set('frontendTools', 'observe');
    const response = await send(`${workerPath}/operations/${operation}?${query}`, { signal });
    if (!dispatchTools && response.ok && response.headers.get('Commander-Frontend-Tools') !== 'observe') {
      await response.body?.cancel();
      throw new Error('Commander did not confirm passive frontend tool observation.');
    }
    return response;
  };
  const observeRun = async ({ runId, signal, dispatchTools }) => {
    const response = await findOperation({ runId, signal });
    if (!response.ok) return response;
    const receipt = await response.json();
    if (receipt?.runId !== runId || typeof receipt.operationId !== 'string' || !receipt.operationId) {
      throw new Error('Commander returned a mismatched operation receipt.');
    }
    return observe({ operationId: receipt.operationId, runId, signal, dispatchTools });
  };
  class CommanderAgent extends HttpAgent {
    run(input) {
      return requireTerminal(super.run(input), input);
    }
    connect(input) {
      // The CopilotKit runtime also connects to idle threads. Resuming a
      // Commander operation requires its original run ID.
      if (input.forwardedProps?.commanderObserve !== true) return super.connect(input);
      const { runId } = input;
      const signal = this.abortController.signal;
      const http = runHttpRequest(() => observeRun({ runId, signal, dispatchTools: input.forwardedProps.dispatchTools }));
      return requireTerminal(transformHttpEventStream(http, this.debugLogger), input);
    }
  }
  const agent = new CommanderAgent({
    url: new URL(runPath, origin).href,
    threadId: workerId,
    fetch: (_url, options) => send(runPath, options),
  });
  return {
    agent,
    async resume({ runId, signal, dispatchTools = true }, subscriber) {
      if (typeof runId !== 'string' || !runId || runId.length > 128) {
        throw new TypeError('Commander resume requires the submitted run ID.');
      }
      if (agent.isRunning) throw new Error('Detach the active agent stream before resuming.');
      signal?.throwIfAborted();
      lifetime?.throwIfAborted();
      const controller = new AbortController();
      const abort = () => controller.abort(signal.reason);
      signal?.addEventListener('abort', abort, { once: true });
      agent.abortController = controller;
      try {
        return await agent.connectAgent({ runId, forwardedProps: { commanderObserve: true, dispatchTools } }, subscriber);
      } finally {
        signal?.removeEventListener('abort', abort);
        controller.abort();
      }
    },
    workerInfo({ signal } = {}) {
      return send(workerPath, { signal });
    },
    readHistory({ source, view, cursor, recordCursor, turnId, limit, signal } = {}) {
      const query = new URLSearchParams();
      if (source !== undefined) query.set('source', source);
      if (view !== undefined) query.set('view', view);
      if (cursor !== undefined) query.set('cursor', cursor);
      if (recordCursor !== undefined) query.set('recordCursor', recordCursor);
      if (turnId !== undefined) query.set('turnId', turnId);
      if (limit !== undefined) query.set('limit', String(limit));
      return send(`/v1/workers/${worker}/history?${query}`, { signal });
    },
    findOperation,
    observeRun,
    submitToolResult({ operationId, message, signal }) {
      const operation = encodeURIComponent(operationId);
      const call = encodeURIComponent(message.toolCallId);
      return send(`${workerPath}/operations/${operation}/tools/${call}/result`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(message),
        signal,
      });
    },
    observe,
    reply({ requestId, answer, generation, idempotencyKey, signal }) {
      const path = `${workerPath}/requests/${encodeURIComponent(requestId)}/reply`;
      const headers = { 'Content-Type': 'application/json' };
      if (idempotencyKey) headers['Idempotency-Key'] = idempotencyKey;
      return send(path, {
        method: 'POST',
        headers,
        body: JSON.stringify({ answer, generation }),
        signal,
      });
    },
  };
}
