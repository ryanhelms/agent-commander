package actions

import "encoding/json"

// ActionContract describes the payload for one registered action. The executor
// still validates the request and its grant before using an owner-local resource.
type ActionContract struct {
	Description   string          `json:"description"`
	PayloadSchema json.RawMessage `json:"payloadSchema"`
}

func ContractFor(name string) (ActionContract, bool) {
	d, ok := registry[name]
	return ActionContract{Description: d.description, PayloadSchema: json.RawMessage(d.payloadSchema)}, ok
}

const (
	closedObject         = `{"type":"object","additionalProperties":false`
	expectedHeadProperty = `"expectedHead":{"type":"string","pattern":"^[0-9a-f]{40}$","description":"Commit SHA returned by git.head or git.commit."}`
	issueNumberProperty  = `"number":{"type":"integer","minimum":1,"maximum":2147483647}`
)

const contextProperty = `"context":{"type":"array","maxItems":16,"items":{"type":"object","additionalProperties":false,"required":["name","content"],"properties":{"name":{"type":"string","minLength":1,"maxLength":256},"content":{"type":"string","maxLength":98304}}}}`

var registry = register(
	descriptor{
		kind: "repo", name: "git.head", recoverable: true, run: repoHandler,
		description:   "Read the collaboration branch's head, base and name before preparing a change.",
		payloadSchema: closedObject + `}`,
	},
	descriptor{
		kind: "repo", name: "git.commit", run: repoHandler,
		description: "Create a commit on the collaboration branch and return its SHA. Each file value is the full UTF-8 content, up to 64 KiB. Use regular files on repository-relative paths.",
		payloadSchema: closedObject + `,"required":["expectedHead","message","files"],"properties":{` + expectedHeadProperty + `,
			"message":{"type":"string","minLength":1,"maxLength":1024},
			"files":{"type":"object","minProperties":1,"maxProperties":16,"additionalProperties":{"type":"string"}}}}`,
	},
	descriptor{
		kind: "repo", name: "git.push", run: repoHandler,
		description:   "Push the specified head of the collaboration branch to the owner's enrolled GitHub repository.",
		payloadSchema: closedObject + `,"required":["expectedHead"],"properties":{` + expectedHeadProperty + `}}`,
	},
	descriptor{
		kind: "repo", name: "issue.read", recoverable: true, run: issueHandler,
		description:   "Read one GitHub issue by number. Omit the number or pass zero to list open issues.",
		payloadSchema: closedObject + `,"properties":{"number":{"type":"integer","minimum":0,"maximum":2147483647}}}`,
	},
	descriptor{
		kind: "repo", name: "issue.comment", run: issueHandler,
		description:   "Post a comment to the given GitHub issue and return the comment ID. The body is limited to 16 KiB.",
		payloadSchema: closedObject + `,"required":["number","body"],"properties":{` + issueNumberProperty + `,"body":{"type":"string","minLength":1,"maxLength":16384}}}`,
	},
	descriptor{
		kind: "repo", name: "issue.close", run: issueHandler,
		description:   "Close the given GitHub issue on the enrolled repository.",
		payloadSchema: closedObject + `,"required":["number"],"properties":{` + issueNumberProperty + `}}`,
	},
	descriptor{
		kind: "agent", name: "agent.ask", recoverable: true, run: agentHandler,
		description:   "Submit one prompt to the owner's shared worker and return its addressed answer. The prompt is limited to 15 KiB. Optional context items (files, diffs, logs) are limited to 96 KiB in total.",
		payloadSchema: closedObject + `,"required":["text"],"properties":{"text":{"type":"string","minLength":1,"maxLength":15360},` + contextProperty + `}}`,
	},
	descriptor{
		kind: "agent", name: "agent.handoff", recoverable: true, run: handoffHandler,
		description:   "Hand a task to the owner's agent. The owner's Commander starts a new run for it in the shared worker's project and returns the run ID at once. Track it with agent.status and agent.result.",
		payloadSchema: closedObject + `,"required":["title","task"],"properties":{"title":{"type":"string","minLength":1,"maxLength":200},"task":{"type":"string","minLength":1,"maxLength":15360},` + contextProperty + `}}`,
	},
	descriptor{
		kind: "agent", name: "agent.watch", recoverable: true, run: watchHandler,
		description:   "Read the shared worker's live transcript after a cursor. Returns one history page and the worker's state.",
		payloadSchema: closedObject + `,"properties":{"after":{"type":"string","maxLength":4096}}}`,
	},
	descriptor{
		kind: "agent", name: "agent.suggest", recoverable: true, run: agentHandler,
		description:   "Suggest a message to the owner's worker. The owner approves each suggestion before the worker sees it; the result is the worker's answer. Limited to 4 KiB.",
		payloadSchema: closedObject + `,"required":["text"],"properties":{"text":{"type":"string","minLength":1,"maxLength":4096}}}`,
	},
	descriptor{
		kind: "agent", name: "review.request", recoverable: true, run: reviewHandler,
		description:   "Ask the owner's worker to review a diff (up to 96 KiB) or a pull request URL. Returns a summary and findings.",
		payloadSchema: closedObject + `,"required":["title"],"properties":{"title":{"type":"string","minLength":1,"maxLength":200},"diff":{"type":"string","maxLength":98304},"pr":{"type":"string","maxLength":2048},"instructions":{"type":"string","maxLength":4096}}}`,
	},
	descriptor{
		kind: "host", name: "host.run", run: hostHandler,
		description:   "Run one of the host's enrolled commands by name and return its exit code and the last 64 KiB of output. Extra args are appended only when the command allows them.",
		payloadSchema: closedObject + `,"required":["command"],"properties":{"command":{"type":"string","minLength":1,"maxLength":128},"args":{"type":"array","maxItems":32,"items":{"type":"string","maxLength":1024}}}}`,
	},
	descriptor{
		kind: "agent", name: "thread.read", recoverable: true, run: threadHandler,
		description:   "Read the comment thread of a request you sent to this agent.",
		payloadSchema: closedObject + `,"required":["request"],"properties":{"request":{"type":"string","minLength":1,"maxLength":128}}}`,
	},
	descriptor{
		kind: "agent", name: "thread.comment", run: threadHandler,
		description:   "Add a comment to the thread of a request you sent to this agent. The text is limited to 4 KiB.",
		payloadSchema: closedObject + `,"required":["request","text"],"properties":{"request":{"type":"string","minLength":1,"maxLength":128},"text":{"type":"string","minLength":1,"maxLength":4096}}}`,
	},
	descriptor{
		kind: "agent", name: "agent.status", recoverable: true, run: handoffHandler,
		description:   "Read the state and latest summary of a run you handed off.",
		payloadSchema: closedObject + `,"required":["run"],"properties":{"run":{"type":"string","minLength":1,"maxLength":128}}}`,
	},
	descriptor{
		kind: "agent", name: "agent.result", recoverable: true, run: handoffHandler,
		description:   "Read the result and artifacts (report, branch) of a run you handed off.",
		payloadSchema: closedObject + `,"required":["run"],"properties":{"run":{"type":"string","minLength":1,"maxLength":128}}}`,
	},
	descriptor{
		kind: "coordinator", name: "app.build", run: desktopBuildAction,
		description:   "Read the running macOS app build and launch identity. Use a new operation and nonce for each observation and compare the response nonce and observedAt. A receipt or service reconnect alone is not evidence.",
		payloadSchema: closedObject + `,"required":["nonce","issuedAt"],"properties":{"nonce":{"type":"string","pattern":"^[0-9a-f]{32}$","description":"Fresh random 128-bit hex nonce. Never reuse it for another observation."},"issuedAt":{"type":"string","format":"date-time","description":"Current UTC time. A request expires after 90 seconds."}}}`,
	},
	descriptor{
		kind: "coordinator", name: "agent.message", recoverable: true, run: coordinatorMessage,
		description:   "Leave a message in the shared coordinator's inbox. The JSON-encoded message, including quotes and escapes, is limited to 4 KiB.",
		payloadSchema: closedObject + `,"required":["text"],"properties":{"text":{"type":"string","minLength":1,"maxLength":4094}}}`,
	},
)
