// Browser-safe readers for the immutable provider record selected by a prompt.
const previewTypes = {
  image: new Set(['image/png', 'image/jpeg', 'image/gif', 'image/webp', 'image/avif']),
  audio: new Set(['audio/wav', 'audio/x-wav', 'audio/mpeg', 'audio/mp4', 'audio/ogg', 'audio/webm', 'audio/flac']),
};

export function providerPromptReference(activity) {
  if (activity?.source !== 'provider' || activity.kind !== 'provider_prompt_media' ||
      typeof activity.cursor !== 'string' || !activity.cursor || !Number.isSafeInteger(activity.itemCount) ||
      activity.itemCount <= 0) return undefined;
  return { cursor: activity.cursor, pageCursor: activity.pageCursor, itemCount: activity.itemCount };
}

function mediaPart(block, claude) {
  if (!block || typeof block !== 'object') return;
  const kind = !claude && block.type === 'localImage' ? 'image' : block.type;
  if (kind !== 'image' && kind !== 'audio') return;
  const source = (claude ? block.source : block) ?? {};
  const location = source.url ?? source.path;
  const encoded = typeof location === 'string' && /^data:([^;,]+);base64,(.*)$/isu.exec(location);
  const nativeMime = encoded ? encoded[1] : source.media_type ?? source.mimeType;
  const mime = typeof nativeMime === 'string' ? nativeMime.toLowerCase() : undefined;
  const bytes = encoded ? encoded[2] : source.data;
  const item = { kind, mime };
  if (typeof bytes === 'string' && previewTypes[kind].has(mime) && /^[A-Za-z0-9+/]+={0,2}$/u.test(bytes)) {
    item.preview = `data:${mime};base64,${bytes}`;
  } else if (typeof location === 'string' && !/^data:/iu.test(location)) {
    item.reference = location;
  }
  return item;
}

function sourceJSON(body) {
  if (body?.mediaType !== 'application/json' || typeof body.data !== 'string') return;
  try {
    const bytes = Uint8Array.from(atob(body.data), c => c.charCodeAt(0));
    return JSON.parse(new TextDecoder().decode(bytes));
  } catch { return undefined; }
}

/** Only the user's immediate content array is inspected. Sibling records and tool output have their own provenance. */
export function providerPromptMedia(record) {
  if (!record?.cursor || record.sourceCursor !== record.cursor) return [];
  const body = record.sourceRecord ?? record.extension;
  if (!['claude.history.message', 'codex.history.item'].includes(body?.type)) return [];
  const original = sourceJSON(body);
  const claude = body.type === 'claude.history.message';
  if (original?.type !== (claude ? 'user' : 'userMessage')) return [];
  const content = claude ? original.message?.content : original.content;
  return Array.isArray(content) ? content.map(block => mediaPart(block, claude)).filter(Boolean) : [];
}

/** Preserve older supplemental record inspection, separately from a prompt attachment action. */
export function providerSupplementalMedia(record) {
  const body = record?.extension;
  if (!['claude.image', 'claude.audio', 'codex.user.image', 'codex.user.audio', 'codex.user.localImage'].includes(body?.type)) return;
  return mediaPart(sourceJSON(body), body.type.startsWith('claude.'));
}

export function selectedProviderMedia(page, reference) {
  const records = page?.observations;
  if (records?.length === 1 && records[0].gap) throw new Error(records[0].gap.reason || 'The original provider record is unavailable.');
  if (!Array.isArray(records) || records.length !== 1 || page.nextCursor || records[0].cursor !== reference.cursor) {
    throw new Error('Commander did not return the selected provider record.');
  }
  const items = providerPromptMedia(records[0]);
  if (items.length !== reference.itemCount) throw new Error('The selected provider record does not contain the expected attachments.');
  return items;
}
