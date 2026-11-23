# Local and SSH workers

A temporary loopback OpenSSH server used generated keys, explicit host-key verification and a separate disposable checkout. The test used a real Claude process over SSH and the native macOS cockpit. Both sides of the SSH connection ran on the same Mac.

1. The coordinator delegated Local Atlas on `localhost` and Remote Delta on `qa-remote` through `commander_delegate`. The worker wall showed `local-checkout` and `remote-checkout` under their respective hosts.
2. Local Atlas completed and reported `LOCAL-ATLAS-42`. Remote Delta posted its own question through the reverse Unix socket.
3. Using Computer Use, I opened Remote Delta's request and sent `CLOUD-LANTERN-84`. Remote Delta used the reply in its final response and reported it with MCP. Local Atlas stayed completed.
4. A fresh Commander service loaded a copy of the QA state. Remote Delta's saved output was empty. Through the owner API, the new service read the assistant's response from its original host-native session, traversing multiple pages over SSH. Every returned record referred to the expected native session ID.

The relay regression test requires the exact worker credential before forwarding. Missing credentials, another worker's credentials, and duplicate authorization headers produce HTTP 401. On accepted requests the normal Commander API still enforces the worker's role and ownership.

This run tested one SSH-only profile. The host CLI also built as static Linux amd64 and arm64 executables. The arm64 executable printed its usage in the local Linux Docker VM with networking disabled. A real SSH connection to a separate machine, persistent helpers, and live recovery across an SSH disconnect remain unverified.

## Linux container fixture

A separate Linux arm64 Docker container runs OpenSSH, Node 24, Claude Code 2.1.330, the pinned ACP adapters and the Linux `agentctl` binary. Its published SSH port binds to localhost. SSH used a generated test key and a pinned host key for the non-root `qa` account. The container reached the Mac through a reverse Unix socket. In this image, `AllowTcpForwarding no` prevented the Unix forward. The fixture permits forwarding with TCP destinations and listeners explicitly set to `none` and enables Unix forwarding.

The container has a dedicated Claude profile and a checkout at `/home/qa/remote-checkout`. The initial fixture run preceded sign-in. The authenticated run is recorded below.

Computer Use verified a separate test with a real local Claude coordinator and an ACP fixture running on Linux. The coordinator delegated one real local Claude worker and one Linux fixture worker. The cockpit showed `localhost` and `local-checkout` for Local Atlas, and `qa-linux` and `remote-checkout` for Remote Delta. The Linux fixture sent its question through the real remote `agentctl mcp` process and its scoped reverse socket. A reply entered on Remote Delta's request returned `Linux accepted LINUX-SOCKET-53` to its console. Local Atlas stayed completed. The Linux fixture used deterministic ACP responses.

## Authenticated Linux worker

The local Claude coordinator delegated Local Atlas to `localhost` and Linux Delta to the signed-in `qa-linux` container. Computer Use showed both live Claude workers on the same wall with `local-checkout` and `remote-checkout`. Linux Delta asked its own question through MCP. A reply sent through its request card produced `NATIVE-LINUX-56` in its console and result. Local Atlas stayed completed with `LOCAL-ATLAS-42`.

After quitting the app, the isolated daemon restarted with empty persisted console fields and the original native bindings. The same app bundle and bundle ID reopened the run, and both assistant responses appeared under their original workers. Linux Delta's transcript came from its native Claude session through the Linux SSH history reader.
