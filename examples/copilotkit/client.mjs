import { CopilotKitCore } from '@copilotkit/core';
import { providerPromptMedia, providerPromptReference, providerSupplementalMedia, selectedProviderMedia } from '@agent-commander/copilotkit/provider-media';

const headers = { authorization: 'Bearer ' + location.hash.slice(1) };
const core = new CopilotKitCore({ runtimeUrl: location.origin + '/copilotkit', runtimeTransport: 'rest', headers });
const el = id => document.getElementById(id);
const error = reason => { el('error').textContent = reason.message ?? String(reason); };
async function api(path, init = {}) {
  const response = await fetch(path, { ...init, headers: { ...headers, ...init.headers } });
  if (!response.ok) throw new Error(`HTTP ${response.status}: ${await response.text()}`);
  return response.json();
}
function pre(text, container) {
  const node = document.createElement('pre');
  node.textContent = text;
  container.append(node);
}

function showMedia(item, container) {
  if (!item.preview) return pre(item.reference ?? 'No supported inline preview is available.', container);
  const node = document.createElement(item.kind === 'image' ? 'img' : 'audio');
  if (item.kind === 'image') node.alt = 'Provider attachment';
  else { node.controls = true; node.preload = 'none'; node.setAttribute('aria-label', 'Provider attachment'); }
  node.src = item.preview;
  container.append(node);
}

function attachmentList(items, container) {
  for (const [index, item] of items.entries()) {
    const entry = document.createElement('details');
    const summary = document.createElement('summary');
    summary.textContent = `Attachment ${index + 1} · ${item.mime || item.kind}`;
    entry.append(summary); container.append(entry);
    entry.addEventListener('toggle', () => {
      if (entry.open && entry.childElementCount === 1) showMedia(item, entry);
    });
  }
}

function openAttachments(reference, section) {
  const open = document.createElement('button');
  open.textContent = `Open attachments (${reference.itemCount})`;
  section.append(open);
  open.onclick = async () => {
    open.disabled = true;
    try {
      const query = new URLSearchParams({ recordCursor: reference.cursor });
      if (reference.pageCursor) query.set('cursor', reference.pageCursor);
      const page = await api('/source?' + query);
      attachmentList(selectedProviderMedia(page, reference), section);
    } catch (failure) { error(failure); open.disabled = false; }
  };
}
async function* records(turnId) {
  const query = new URLSearchParams();
  if (turnId) query.set('turnId', turnId);
  for (;;) {
    const page = await api('/source?' + query);
    for (const record of page.observations ?? []) yield record;
    if (!page.nextCursor) return;
    query.set('cursor', page.nextCursor);
  }
}
function displayRecord(record, container, pageCursor) {
  const items = providerPromptMedia(record);
  if (items.length) openAttachments({ cursor: record.cursor, pageCursor, itemCount: items.length }, container);
  const supplemental = providerSupplementalMedia(record);
  if (supplemental) showMedia(supplemental, container);
  const body = record.sourceRecord ?? record.extension;
  if (body?.data) {
    const bytes = Uint8Array.from(atob(body.data), c => c.charCodeAt(0));
    if (body.mediaType === 'application/json') {
      const raw = new TextDecoder().decode(bytes);
      pre(raw, container);
    } else pre(`${body.mediaType ?? 'Source'} (base64)\n${body.data}`, container);
  }
  pre(JSON.stringify(record, null, 2), container);
}
function addToolResult(message) {
  const details = document.createElement('details');
  details.dataset.tool = message.id;
  const summary = document.createElement('summary');
  summary.textContent = 'Tool result · ' + message.toolCallId;
  details.append(summary);
  pre(message.content, details);
  const source = message.metadata?.acp;
  if (source?.source === 'live' && source.cursor && source.turnId) {
    const button = document.createElement('button');
    button.textContent = 'Open original ACP result';
    details.append(button);
    button.onclick = async () => {
      button.disabled = true;
      try {
        for await (const record of records(source.turnId)) {
          if (record.cursor === source.cursor) { displayRecord(record, details); return; }
        }
        throw new Error('The original ACP result has expired.');
      } catch (failure) { error(failure); button.disabled = false; }
    };
  }
  el('results').append(details);
}
async function start() {
  const info = await api('/worker');
  document.querySelector('h1').textContent = `${info.client} · ${info.workerId}`;
  let agent;
  while (!(agent = core.getAgent('commander'))) {
    if (core.runtimeConnectionStatus === 'error') throw new Error('CopilotKit runtime discovery failed.');
    await new Promise(resolve => setTimeout(resolve, 40));
  }
  agent.threadId = info.workerId;
  const send = el('send').querySelector('button');
  send.disabled = info.generation === undefined;
  el('status').textContent = info.generation === undefined ? 'History available' : 'Ready';
  const seen = new Set();
  const pending = new Map();
  let generation = info.generation;
  function render() {
    for (const message of agent.messages) {
      const reference = message.role === 'user' && providerPromptReference(message.metadata?.acp);
      if (reference && !seen.has(message.id)) {
        seen.add(message.id);
        const section = document.createElement('section');
        if (typeof message.content === 'string') pre(message.content, section);
        openAttachments(reference, section); el('user-media').append(section);
      }
      if (message.role === 'tool' && !seen.has(message.id)) { seen.add(message.id); addToolResult(message); }
    }
    el('assistant').textContent = agent.messages.filter(m => m.role === 'assistant' && typeof m.content === 'string')
      .map(m => m.content).join('');
    const active = agent.state?.pendingRequests ?? [];
    for (const [id, form] of pending) {
      if (!active.some(q => q.id === id)) { form.remove(); pending.delete(id); }
    }
    for (const q of active) {
      if (pending.has(q.id)) continue;
      const form = document.createElement('form');
      form.dataset.requestId = q.id;
      const label = document.createElement('label');
      label.textContent = q.question + ' ';
      const input = document.createElement('input');
      input.name = 'answer'; input.required = true; label.append(input);
      const button = document.createElement('button');
      button.textContent = 'Answer'; form.append(label, button);
      pending.set(q.id, form); el('pending').append(form);
      const idempotencyKey = crypto.randomUUID();
      form.onsubmit = async event => {
        event.preventDefault(); button.disabled = true;
        try {
          await api('/reply', { method: 'POST', headers: { 'content-type': 'application/json' },
            body: JSON.stringify({ requestId: q.id, answer: input.value, generation, idempotencyKey }) });
        } catch (failure) { error(failure); button.disabled = false; }
      };
    }
  }
  agent.subscribe({ onStateChanged: render, onMessagesChanged: render });
  const storageKey = 'commander.run.' + info.workerId;
  const reconnect = el('reconnect');
  let currentRunId = sessionStorage.getItem(storageKey);
  reconnect.hidden = !currentRunId;
  if (currentRunId) send.disabled = true;
  async function follow(resuming) {
    send.disabled = reconnect.disabled = true;
    el('error').textContent = ''; el('status').textContent = resuming ? 'Reconnecting' : 'Running';
    let finished = false, runError, operationStatus;
    const terminal = agent.subscribe({
      onRunFinishedEvent: () => { finished = true; },
      onRunErrorEvent: ({ event }) => { runError = new Error(event.message); },
      onStateChanged: ({ state }) => { operationStatus = state?.operationStatus; },
    });
    try {
      if (resuming) {
        await agent.connectAgent({ runId: currentRunId, forwardedProps: { commanderObserve: true } });
      } else {
        ({ generation } = await api('/worker'));
        if (generation === undefined) throw new Error('Take worker input control in Commander.');
        currentRunId = crypto.randomUUID();
        sessionStorage.setItem(storageKey, currentRunId);
        agent.addMessage({ id: currentRunId, role: 'user', content: el('send').elements.prompt.value });
        await core.runAgent({ agent, runId: currentRunId, forwardedProps: { generation } });
      }
      if (runError) throw runError;
      if (!finished) throw new Error('The stream closed before Commander confirmed the outcome.');
      currentRunId = null;
      render(); el('status').textContent = 'Finished';
    } catch (failure) {
      error(failure);
      if ((resuming && failure?.status === 404) || (runError && operationStatus === 'failed')) currentRunId = null;
      el('status').textContent = currentRunId ? 'Outcome unconfirmed' : 'Failed';
    } finally {
      terminal.unsubscribe();
      if (!currentRunId) sessionStorage.removeItem(storageKey);
      reconnect.hidden = !currentRunId;
      reconnect.disabled = false;
      send.disabled = Boolean(currentRunId) || generation === undefined;
    }
  }
  reconnect.onclick = () => follow(true);
  el('send').onsubmit = event => {
    event.preventDefault();
    void follow(false);
  };
}
let historyCursor;
el('history').onclick = async () => {
  const output = el('records');
  if (!historyCursor) output.replaceChildren();
  el('history').disabled = true;
  try {
    const query = new URLSearchParams();
    if (historyCursor) query.set('cursor', historyCursor);
    const pageCursor = historyCursor;
    const page = await api('/source?' + query);
    for (const record of page.observations ?? []) {
      const details = document.createElement('details');
      const summary = document.createElement('summary');
      const speaker = record.text?.speaker?.replace(/^SPEAKER_/, '').toLowerCase();
      summary.textContent = record.gap?.reason ?? record.tool?.name ?? (speaker && speaker + ' message') ??
        record.extension?.type ?? record.sourceRecord?.type ?? 'Provider record';
      details.append(summary); output.append(details);
      details.addEventListener('toggle', () => {
        if (details.open && details.childElementCount === 1) displayRecord(record, details, pageCursor);
      });
    }
    historyCursor = page.nextCursor;
    el('history').textContent = historyCursor ? 'More provider records' : 'Refresh provider history';
  } catch (failure) { error(failure); }
  finally { el('history').disabled = false; }
};
start().catch(error);
