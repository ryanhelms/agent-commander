import assert from 'node:assert/strict';
import { test } from 'node:test';
import { buildTimeline, decodeSourceText, inlineSourceMedia, readState, sourceMedia, wireFields } from './contract.ts';

test('archived attachment-only user prompts keep their owner and page hint in the conversation', () => {
  const descriptor = { source: 'provider', kind: 'provider_prompt_media', cursor: 'owner', pageCursor: 'hint', itemCount: 2 };
  const [row] = buildTimeline([{ id: 'm', role: 'user', content: '', metadata: { acp: descriptor } }]);
  assert.deepEqual(row, { kind: 'message', speaker: 'user', id: 'm', text: '',
    attachments: { cursor: 'owner', pageCursor: 'hint', itemCount: 2 } });
});

test('shows raw wire tokens without parsing them as JavaScript values', () => {
  const additional = '{"vendor":[9007199254740993,null,false],"vendor":{"wide":-9007199254740999}}';
  const id = String.raw`"req\u0031"`;
  assert.deepEqual(wireFields({ kind: 'WIRE_MESSAGE_KIND_REQUEST', method: 'session/request_permission',
    protocolVersion: '2.0', idJson: id, additionalFieldsJson: additional }), [
    ['Message kind', 'WIRE_MESSAGE_KIND_REQUEST'], ['Method', 'session/request_permission'],
    ['Protocol version', '"2.0"'], ['Request ID', id], ['Additional fields', additional],
  ]);
  assert.deepEqual(wireFields({}), []);
  assert.deepEqual(wireFields({ omittedIdBytes: '0', omittedProtocolVersionBytes: '0',
    omittedAdditionalFieldsBytes: '0', idJsonBytes: '', additionalFieldsJsonBytes: '',
    protocolVersionJsonBytes: '', additionalFieldsJson: '' }), []);
  assert.deepEqual(wireFields({ idJson: 'null', protocolVersion: '' }), [
    ['Protocol version', '""'], ['Request ID', 'null'],
  ]);
  assert.deepEqual(wireFields({ protocolVersionJsonBytes: '/w==', idJsonBytes: 'Iv8i',
    additionalFieldsJsonBytes: 'e/99' }), [
    ['Protocol version (base64)', '/w=='], ['Request ID (base64)', 'Iv8i'],
    ['Additional fields (base64)', 'e/99'],
  ]);
  assert.deepEqual(wireFields({ omittedProtocolVersionBytes: '3871', omittedIdBytes: '258',
    omittedAdditionalFieldsBytes: '9007199254740993' }), [
    ['Protocol version bytes omitted', '3871'], ['Request ID bytes omitted', '258'],
    ['Additional field bytes omitted', '9007199254740993'],
  ]);
});

const call = id => ({
  id: 'assistant-' + id, role: 'assistant',
  toolCalls: [{ id, function: { name: 'Read', arguments: '{}' } }],
});
const result = (id, content, error) => ({ id: 'result-' + id, role: 'tool', toolCallId: id, content, error });

const chunk = (id, content, fields = {}) => ({
  id, role: 'assistant', content,
  metadata: { acp: { source: 'live', kind: 'agent_message_chunk', contentType: 'text', ...fields } },
});

test('keeps the exact text, contributing record IDs and stable row identity of a streamed reply', () => {
  const tokens = ['\n', 'two', ' ', 'words', '\n  '];
  const messages = tokens.map((part, i) => chunk('w:' + i, part, { turnId: 'turn', messageId: 'reply' }));
  const expected = len => [{
    kind: 'message', id: 'w:0#chunks', speaker: 'assistant', text: tokens.slice(0, len).join(''),
    sourceIds: messages.slice(0, len).map(m => m.id),
  }];
  for (let len = 1; len <= messages.length; len++) {
    assert.deepEqual(buildTimeline(messages.slice(0, len)), expected(len));
  }
});

test('separates changes of turn, message ID, source, content type and intervening records', () => {
  const messages = [
    chunk('1', 'a'), chunk('2', 'b'),
    chunk('3', 'c', { turnId: 't' }), chunk('4', 'd', { turnId: 'u' }),
    chunk('5', 'e', { turnId: 'u', messageId: 'm' }), chunk('6', 'f', { turnId: 'u', messageId: 'n' }),
    chunk('7', 'archive', { source: 'journal' }), chunk('8', 'g'),
    chunk('9', [{ type: 'text', text: 'structured' }]), chunk('10', 'h'),
    call('read'), chunk('11', 'i'), result('read', 'done'), chunk('12', 'j'),
    { id: 'user', role: 'user', content: 'next' }, chunk('13', 'k'),
    { id: 'legacy', role: 'assistant', content: 'plain' }, chunk('14', 'l'),
    chunk('15', 'image', { contentType: 'image' }), chunk('16', 'm'),
  ];
  assert.deepEqual(buildTimeline(messages).map(row => [row.id, row.text ?? row.result]), [
    ['1#chunks', 'ab'], ['3#chunks', 'c'], ['4#chunks', 'd'], ['5#chunks', 'e'], ['6#chunks', 'f'],
    ['7', 'archive'], ['8#chunks', 'g'], ['9', 'structured'], ['10#chunks', 'h'], ['read', 'done'],
    ['11#chunks', 'i'], ['12#chunks', 'j'], ['user', 'next'], ['13#chunks', 'k'], ['legacy', 'plain'],
    ['14#chunks', 'l'], ['15', 'image'], ['16#chunks', 'm'],
  ]);
});

test('keeps independent tool errors, result data and typed terminal statuses', () => {
  const entries = buildTimeline([
    call('partial'), result('partial', 'Partial file contents', 'Read timed out.'),
    call('same'), result('same', 'Part one\nTool failed.\nPart two', 'Tool failed.'),
    call('declined'), result('declined', '', 'Tool declined.'),
    call('cancelled'), result('cancelled', '', 'Tool cancelled.'),
    call('interrupted'), result('interrupted', '', 'Tool interrupted.'),
    result('orphan', undefined, 'The original call is outside the retained window.'),
  ]);
  assert.deepEqual(entries.map(entry => [entry.kind, entry.termination, entry.result ?? entry.text]), [
    ['activity', 'failed', 'Read timed out.\nPartial file contents'],
    ['activity', 'failed', 'Part one\nTool failed.\nPart two'],
    ['activity', 'declined', 'Tool declined.'],
    ['activity', 'cancelled', 'Tool cancelled.'],
    ['activity', 'interrupted', 'Tool interrupted.'],
    ['diagnostic', undefined, 'The original call is outside the retained window.'],
  ]);
});

test('keeps opaque source bytes available and renders only allowlisted inline media', () => {
  assert.equal(decodeSourceText('eyJrZXkiOiJ2YWx1ZSJ9', 'application/json'), '{"key":"value"}');
  assert.equal(decodeSourceText('/w==', 'text/plain'), undefined);
  assert.equal(decodeSourceText('AAE=', 'application/octet-stream'), undefined);
  assert.deepEqual(inlineSourceMedia('image/png', 'AAE='), { kind: 'image', url: 'data:image/png;base64,AAE=' });
  assert.equal(inlineSourceMedia('image/svg+xml', 'AAE='), undefined);
  assert.deepEqual(sourceMedia(JSON.stringify({ items: [
    { mimeType: 'image/png', uri: 'https://example.invalid/external.png' },
    { mimeType: 'image/png', data: 'AAE=' },
    { type: 'image', url: 'data:image/png;base64,AQI=' },
    { url: 'https://example.invalid/remote.png' },
    { image_url: 'data:image/svg+xml;base64,AAE=' },
  ] })), [{ kind: 'image', url: 'data:image/png;base64,AAE=' }, { kind: 'image', url: 'data:image/png;base64,AQI=' }]);
});

test('shows the attached worker status before AG-UI publishes a run state', () => {
  assert.equal(readState({}, 'stopped').status, 'stopped');
  assert.equal(readState({ status: 'waiting' }, 'working').status, 'waiting');
  assert.equal(readState({ status: 'unrecognized' }, 'idle').status, undefined);
});
