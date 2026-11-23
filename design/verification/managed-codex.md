# Managed Codex verification

The managed route uses the pinned Codex ACP adapter and the installed native Codex App Server. It reads from a dedicated native profile. A bridge checks effective profile configuration, replaces adapter-supplied launch policy with the assignment policy and validates the native thread identity before accepting turn operations.

## Local protocol test

The native isolation regression checks Codex 0.171.0 with harmless MCP fixture processes and a synthetic credential. A clean profile started the explicitly supplied MCP process while the checkout's MCP process stayed absent. In the control case, a user-configured process started despite the untrusted checkout. The bridge subsequently rejected that contaminated profile before either fixture process could start.

A loopback Responses API fixture exercised the built Go bridge and upstream ACP adapter with the real local Codex executable. No provider account or external model call was used in this test.

1. ACP opened a scoped native session and started only the authorized MCP fixture.
2. The first turn sent a literal multiline prompt with shell punctuation. The SDK-facing ACP feed streamed the assistant fixture response and returned `end_turn`.
3. A cancellation addressed the second turn after its first streamed text. Codex returned `cancelled`.
4. A fresh host-reader process queried the original native thread and walked multiple pages. Its observations contained the exact multiline user prompt and assistant response.

This test confirms transport, policy and native history behavior independently of model behavior. The authenticated cockpit run is recorded below.

A disposable Commander daemon returned HTTP 409 for a configured Codex profile with no native sign-in. The API persisted no run or worker and created no launch job. The Go tests also cover accepting the same profile after native sign-in becomes available and rejecting an unavailable delegated client without consuming the delegation's retry key.

## Mixed run through the Commander API

A real Claude coordinator delegated one Claude worker and one managed Codex worker through MCP into the same run. The Codex executable used a loopback model fixture. The first attempt found that the packaged launcher passed an empty model-provider override. The launcher now removes inherited adapter overrides before starting Codex.

In the passing run, the Codex worker streamed and accepted a targeted interrupt. Claude's pending question kept its original request ID and received `CLAUDE_TARGET_33`. Codex stayed idle until a separately addressed multiline follow-up reopened its original live conversation. The native history endpoint returned the exact Codex prompt, including the literal dollar sign, and `CODEX_TARGETED_REPLY_58`. The Claude answer was absent from the Codex observations. The checkout-configured MCP process stayed absent throughout.

The mixed run used the real Commander HTTP API and tool ownership rules.

## Cold cockpit feed

A fresh Commander daemon opened a copy of the completed mixed fixture's saved run while a previous stop was settling. The initial AG-UI workspace snapshot contained no worker transcripts. As the native readers completed, the same stream delivered both assistant responses under their original Commander worker IDs and native session IDs. Codex's restored conversation excluded the answer sent to Claude.

The initial attempt exposed a recovery race. A history read was discarded when the worker moved from stopping to stopped. The service now accepts the read across inactive state changes when the native binding and console sequence still match. A regression test covers that transition and discards the same read if the worker starts a new turn.

## Model-facing tool policy

A loopback model fixture captured the tools the real Codex executable offered on two turns. The Commander test server advertised both `commander_result` and the out-of-scope `commander_delegate`. The model received only `commander_result` in the Commander namespace. The only other exposed tools were MCP resource browsing and a user-input request. Goals, web search, image viewing, shell execution, file patching, agent spawning and permission escalation were absent. Streaming, targeted interruption and cold native history still passed with the restricted tool list.

## Authenticated mixed run

Claude and Codex both used their real accounts in an isolated Commander run. The first attempt established that Codex's worker saw the allowed MCP request tool, but the native approval policy denied the call. Commander now approves each allowlisted Commander tool explicitly. The API still checks the worker's identity and ownership on every call. The Codex checkout remains untrusted, and the read-only sandbox and escalation policy remain in force.

The default model reported a capacity error. A temporary QA profile setting selected `gpt-6.1-sol` for the passing run. The Claude coordinator delegated both workers. Each worker posted a distinct pending question. The API interrupted Codex while Claude's request stayed pending. Claude returned its own synthetic answer. An addressed multiline follow-up then reached the same Codex session, which returned `LIVE_CODEX_TARGETED_58`. Native history preserved the exact prompt, including the literal dollar sign, and the assistant response. The QA model override was removed after the run.

A fresh daemon reopened that authenticated run. Its first cockpit AG-UI snapshot contained no worker transcripts. The subsequent feed restored both assistant responses under their original Commander worker IDs and native session IDs.

The current macOS app built and signed successfully. A second authenticated run confirmed the same worker isolation. A temporary verifier compiled from the app's production Swift event-stream decoder restored both assistant replies under their original worker IDs from a fresh daemon.

## Computer Use check in the macOS cockpit

An isolated authenticated run showed Claude Reply Check and Codex Reply Check on the same worker wall, each with a distinct pending question. Sending `VISUAL-CLAUDE-73` in Claude’s reply card left the Codex request pending. Interrupting Codex moved only Codex to idle while Claude stayed completed. A follow-up sent from the focused Codex console produced `VISUAL-CODEX-84`.

After quitting the QA app, the isolated service was restarted with the same three native bindings and empty persisted output and console fields. Reopening the QA window restored Claude’s assistant reply and Codex’s assistant reply on their original tiles. The separate interactive run opened for the developer was left alone.
