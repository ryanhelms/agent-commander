// A minimal Agent Commander plugin: an MCP server over stdio with no dependencies.
// Real plugins can use an official MCP SDK instead; the wire protocol is the same.
import { readdir } from "node:fs/promises";
import { createInterface } from "node:readline";

const tools = [
  {
    name: "echo",
    description: "Echo text back with the project scope and settings Commander sent.",
    inputSchema: {
      type: "object",
      required: ["text"],
      additionalProperties: false,
      properties: { text: { type: "string", maxLength: 1000 } },
    },
  },
  {
    name: "project_files",
    description: "List the top-level entries of the project this tool is granted to.",
    inputSchema: { type: "object", additionalProperties: false, properties: {} },
  },
];

async function callTool(name, args, meta) {
  const scope = meta?.["agentcommander/scope"] ?? {};
  const settings = meta?.["agentcommander/settings"] ?? {};
  switch (name) {
    case "echo":
      return { greeting: settings.greeting ?? "Hello", text: args.text, scope };
    case "project_files": {
      if (!scope.project_path) throw new Error("no project scope");
      const entries = await readdir(scope.project_path, { withFileTypes: true });
      return {
        project: scope.project_path,
        entries: entries
          .filter((e) => !e.name.startsWith("."))
          .slice(0, 200)
          .map((e) => ({ name: e.name, kind: e.isDirectory() ? "dir" : "file" })),
      };
    }
    default:
      throw new Error(`unknown tool ${name}`);
  }
}

function send(message) {
  process.stdout.write(JSON.stringify({ jsonrpc: "2.0", ...message }) + "\n");
}

async function handle({ id, method, params }) {
  switch (method) {
    case "initialize":
      return {
        protocolVersion: params.protocolVersion,
        capabilities: { tools: {} },
        serverInfo: { name: "example.hello", version: "1.0.0" },
      };
    case "ping":
      return {};
    case "tools/list":
      return { tools };
    case "tools/call":
      try {
        const result = await callTool(params.name, params.arguments ?? {}, params._meta);
        return { content: [{ type: "text", text: JSON.stringify(result) }], structuredContent: result };
      } catch (error) {
        return { content: [{ type: "text", text: String(error.message) }], isError: true };
      }
    default:
      if (id === undefined) return undefined; // notifications need no reply
      throw Object.assign(new Error(`method not found: ${method}`), { code: -32601 });
  }
}

createInterface({ input: process.stdin }).on("line", async (line) => {
  if (!line.trim()) return;
  const message = JSON.parse(line);
  try {
    const result = await handle(message);
    if (message.id !== undefined && result !== undefined) send({ id: message.id, result });
  } catch (error) {
    if (message.id !== undefined) send({ id: message.id, error: { code: error.code ?? -32603, message: error.message } });
  }
});
