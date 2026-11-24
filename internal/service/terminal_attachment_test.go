package service

import (
	"context"
	"encoding/json"
	"testing"
)

type terminalFixtureLauncher struct {
	continuityLauncher
	resolve func(string) TerminalAttachment
}

func (p terminalFixtureLauncher) ResolveTerminal(_ context.Context, id string) (TerminalAttachment, error) {
	return p.resolve(id), nil
}

func TestTerminalAttachmentOwnerAndLocalIdentity(t *testing.T) {
	f := newFixture(t)
	var calls int
	launcher := terminalFixtureLauncher{continuityLauncher: continuityLauncher{recorder: f.p}}
	launcher.resolve = func(id string) TerminalAttachment {
		calls++
		return TerminalAttachment{WorkerID: id, SocketPath: "/tmp/test.sock", SessionID: "$17"}
	}
	var err error
	if f.api, err = New(f.dir, launcher); err != nil {
		t.Fatal(err)
	}
	coord := f.run()
	worker := f.delegate(coord, "local")
	path := "/v1/workers/" + worker.ID + "/terminal"
	var got TerminalAttachment
	if err := json.Unmarshal(f.call("GET", path, "", nil, 200, ""), &got); err != nil ||
		got.WorkerID != worker.ID || got.SessionID != "$17" || got.SocketPath != "/tmp/test.sock" {
		t.Fatalf("unexpected attachment: %+v, %v", got, err)
	}
	f.call("GET", path, worker.Token, nil, 403, "")
	f.call("GET", path, coord.Token, nil, 403, "")
	f.call("GET", "/v1/workers/missing/terminal", "", nil, 404, "")
	f.call("POST", "/v1/runs/"+coord.RunID+"/workers", "", map[string]string{
		"name": "remote", "task": "remote worker", "host": "linux-build",
	}, 201, "")
	remote := f.launched()
	f.call("GET", "/v1/workers/"+remote.ID+"/terminal", "", nil, 501, "")
	if calls != 1 {
		t.Fatalf("resolved %d times; only the owner-local lookup should reach tmux", calls)
	}
}
