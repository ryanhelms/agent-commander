# Verified catalog notice delivery

The driver starts two Commander services on independent private Unix sockets and publishes signed ACP entries on a loopback HTTPS registry. Each catalog operation runs in its own process. The fixture adapter answers a real ACP v1 handshake when activated. Each service also owns a saved conversation so the test can compare its projected content across catalog changes.

The macOS arm64 check observed the primary stream progress from empty to the verified 1.0.0 → 2.0.0 notice, back to empty on activation, then to the same notice after rollback and a fresh refresh. The publisher signature failure made zero update downloads. Concurrent and repeated refreshes reused one download and generated one notification. The active executable stayed pinned until activation. Reconnecting returned the current snapshot. The other service kept its own notice through the first service's activation, and the earlier transcript remained identical. [Observed frames](macos.json)

The same check passed inside a network-disabled Linux arm64 container with a loopback publisher. Both services, activation, rollback and every refresh used the same production CLI binary. [Linux frames](linux.json)

Computer Use opened the optimized native cockpit on the fixture's owner socket. A signed CLI refresh displayed one toolbar notice for `catalog-fixture`. The popover identified 1.0.0 as current and 2.0.0 as staged. A repeated refresh kept a single row. Activation cleared the notice and the archived conversation stayed visible. After rollback, closing and reopening the fixture cockpit and issuing another CLI refresh displayed the notice again. [Native popover](native-popover.jpg)

Build and run from the repository root with Node and OpenSSL available. On macOS the test-only catalog executable invokes the normal CLI entry point with a process-local fixture certificate pool. The Commander service is the normal executable. Linux can use the normal CLI for every subprocess with `SSL_CERT_FILE` scoped to that command.

```sh
qa_dir=$(mktemp -d)
go build -o "$qa_dir/agentctl" ./cmd/agentctl
go test -c -o "$qa_dir/catalog-test" ./cmd/agentctl
node design/verification/catalog-notices/verify.mjs \
  --agentctl "$qa_dir/agentctl" --catalog-test "$qa_dir/catalog-test"
```

Add `--serve` to open a disposable service for native inspection. The driver prints its state directory and socket. Enter `refresh` to stage the signed update, `activate` to apply it, `rollback` to restore 1.0.0, or `quit` to close the fixture.
