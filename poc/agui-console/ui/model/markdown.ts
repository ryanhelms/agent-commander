// A small, safe Markdown subset for assistant output: fenced code blocks, inline code, bold and
// headings. Everything else is left as written. The result is plain data rendered as React text
// nodes, so no HTML from the transcript is ever interpreted.

export type Span = { kind: "text" | "code" | "bold"; text: string };

export type Block =
  | { kind: "line"; heading: boolean; spans: Span[] }
  | { kind: "code"; lang?: string; text: string };

const INLINE = /(`[^`\n]+`|\*\*[^*\n]+\*\*)/g;

function inline(line: string): Span[] {
  const spans: Span[] = [];
  for (const part of line.split(INLINE)) {
    if (!part) continue;
    if (part.length > 2 && part.startsWith("`") && part.endsWith("`")) {
      spans.push({ kind: "code", text: part.slice(1, -1) });
    } else if (part.length > 4 && part.startsWith("**") && part.endsWith("**")) {
      spans.push({ kind: "bold", text: part.slice(2, -2) });
    } else {
      spans.push({ kind: "text", text: part });
    }
  }
  return spans;
}

export function parseMarkdown(source: string): Block[] {
  const blocks: Block[] = [];
  let fence: { marker: string; lang?: string; lines: string[] } | null = null;

  for (const line of source.replace(/\r\n?/g, "\n").split("\n")) {
    const edge = /^\s*(```+|~~~+)\s*([\w+#.-]*)\s*$/.exec(line);
    if (fence) {
      if (edge && !edge[2] && edge[1].startsWith(fence.marker)) {
        blocks.push({ kind: "code", lang: fence.lang, text: fence.lines.join("\n") });
        fence = null;
      } else {
        fence.lines.push(line);
      }
      continue;
    }
    if (edge) {
      fence = { marker: edge[1], lang: edge[2] || undefined, lines: [] };
      continue;
    }
    const heading = /^#{1,6}\s+(.*)$/.exec(line);
    blocks.push({ kind: "line", heading: Boolean(heading), spans: inline(heading ? heading[1] : line) });
  }
  // A fence that is still open is output that is still streaming.
  if (fence) blocks.push({ kind: "code", lang: fence.lang, text: fence.lines.join("\n") });
  return blocks;
}
