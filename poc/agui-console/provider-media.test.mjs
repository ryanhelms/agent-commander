import assert from 'node:assert/strict';
import { test } from 'node:test';
import { providerPromptMedia, providerPromptReference, providerSupplementalMedia, selectedProviderMedia } from './connector/provider-media.mjs';

const reference = { cursor: 'original+/=', pageCursor: 'page+/=', itemCount: 3 };
const url = 'data:image/png;base64,AQI=';
const owner = (type, original) => ({
  cursor: reference.cursor, sourceCursor: reference.cursor,
  sourceRecord: { type, mediaType: 'application/json', data: Buffer.from(JSON.stringify(original)).toString('base64') },
});

test('inline audio stays playable on both native shapes and supplemental records remain separate', () => {
  const preview = 'data:audio/wav;base64,V0FWRQ==';
  const claude = { type: 'audio', source: { type: 'base64', media_type: 'audio/wav', data: 'V0FWRQ==' } };
  const codex = { type: 'audio', url: preview };
  for (const [record, extensionType, block] of [
    [owner('claude.history.message', { type: 'user', message: { content: [claude] } }), 'claude.audio', claude],
    [owner('codex.history.item', { type: 'userMessage', content: [codex] }), 'codex.user.audio', codex],
  ]) {
    const expected = { kind: 'audio', mime: 'audio/wav', preview };
    assert.deepEqual(providerPromptMedia(record), [expected]);
    const supplemental = { cursor: 'sibling', sourceCursor: record.cursor, extension: { type: extensionType,
      mediaType: 'application/json', data: Buffer.from(JSON.stringify(block)).toString('base64') } };
    assert.deepEqual(providerSupplementalMedia(supplemental), expected);
    assert.deepEqual(providerPromptMedia(supplemental), []);
  }
});

test('prompt media selects the exact owner, keeps native order and repeated items, and leaves references inert', () => {
  const claude = owner('claude.history.message', { type: 'user', message: { content: [
    { type: 'image', source: { type: 'base64', media_type: 'image/png', data: 'AQI=' } },
    { type: 'tool_result', content: [{ type: 'image', source: { media_type: 'image/jpeg', data: 'AA==' } }] },
    { type: 'audio', source: { type: 'url', url: 'https://media.invalid/audio.wav' } },
    { type: 'image', source: { type: 'base64', media_type: 'image/png', data: 'AQI=' } },
  ] } });
  const codex = owner('codex.history.item', { type: 'userMessage', content: [
    { type: 'image', url }, { type: 'localImage', path: '/fixture/local.png' }, { type: 'image', url },
  ] });
  assert.deepEqual(providerPromptReference({ kind: 'provider_prompt_media', source: 'provider', ...reference }), reference);
  for (const [record, link] of [[claude, 'https://media.invalid/audio.wav'], [codex, '/fixture/local.png']]) {
    const items = selectedProviderMedia({ observations: [record] }, reference);
    assert.equal(items.length, 3);
    assert.equal(items[0].preview, url);
    assert.equal(items[1].reference, link);
    assert.equal(items[1].preview, undefined);
    assert.deepEqual(items[0], items[2]);
    assert.deepEqual(providerPromptMedia({ ...record, cursor: 'supplement' }), []);
    assert.throws(() => selectedProviderMedia({ observations: [{ ...record, cursor: 'different' }] }, reference), /selected provider record/);
    assert.throws(() => selectedProviderMedia({ observations: [record], nextCursor: 'extra-page' }, reference), /selected provider record/);
  }
  assert.throws(() => selectedProviderMedia({ observations: [{ gap: { reason: 'Original expired' } }] }, reference), /Original expired/);
  assert.deepEqual(providerPromptMedia(owner('codex.history.item', { type: 'tool', content: [{ type: 'image', url }] })), []);
  assert.equal(providerPromptMedia(owner('codex.history.item', { type: 'userMessage', content: [{ type: 'image', url: 'data:image/svg+xml;base64,AQI=' }] }))[0].preview, undefined);
});
