package service

import (
	"bytes"
	"encoding/json"
	"slices"
	"strconv"
	"strings"
	"testing"
	"unicode/utf8"

	"agentcommander/internal/acpprocessor"
)

func TestWorkspaceRevisionsRetainOrderedChangesAndRecoverExpiredCursor(t *testing.T) {
	const untouched = "private workspace sentinel in another worker"
	w := &Worker{ID: "w", RunID: "r"}
	run := &Run{ID: "r", Workers: []*Worker{w, {ID: "quiet", RunID: "r", Output: untouched}}}
	p := workspaceProjection{incrementalReaders: 2}
	p.rebuild([]*Run{run})
	initial, err := p.snapshot(true, false)
	if err != nil || !bytes.Contains(initial, []byte(`"outputChunks":["`+untouched+`"]`)) || bytes.Contains(initial, []byte(`"output":`)) {
		t.Fatalf("initial projection: %s (%v)", initial, err)
	}
	appended := func(i int) {
		text := "event " + strconv.Itoa(i) + "\n"
		e := ConsoleEvent{Sequence: i, Kind: "text", Text: text}
		w.Output += text
		w.Console = append(w.Console, e)
		p.updateWorker(w, text, []ConsoleEvent{e})
	}
	first := p.revision
	appended(1)
	appended(2)
	cursor := first
	for i := 1; i <= 2; i++ {
		frame, next, err := p.next(cursor, true)
		if err != nil || next != cursor+1 || bytes.Contains(frame, []byte(untouched)) {
			t.Fatalf("bad revision %d: %s (%v)", next, frame, err)
		}
		other, _, _ := p.next(cursor, true)
		if &frame[0] != &other[0] {
			t.Fatal("separate encoding for the same revision")
		}
		var event struct {
			Delta []struct {
				Op, Path string
				Value    json.RawMessage
			}
		}
		if err := json.Unmarshal(bytes.TrimSpace(bytes.TrimPrefix(frame, []byte("data: "))), &event); err != nil {
			t.Fatal(err)
		}
		if len(event.Delta) != 2 || event.Delta[1].Path != "/runs/0/workers/0/messages/-" || !bytes.Contains(event.Delta[1].Value, []byte("event "+strconv.Itoa(i))) {
			t.Fatalf("incorrect change: %s", frame)
		}
		cursor = next
	}
	w.State = "working"
	p.rebuild([]*Run{run})
	update, _, _ := p.next(cursor, true)
	if !bytes.Contains(update, []byte(`"/runs/0/workers/0/state"`)) || bytes.Contains(update, []byte(untouched)) || bytes.Contains(update, []byte("event 2")) {
		t.Fatalf("metadata change re-sent history: %s", update)
	}
	for i := 3; i < 80; i++ {
		appended(i)
	}
	recovery, rev, err := p.next(first, true)
	if err != nil || rev != p.revision || !bytes.Contains(recovery, []byte(`"reason":"workspace_delta_expired"`)) || !bytes.Contains(recovery, []byte(`"id":"w:79"`)) {
		t.Fatalf("incomplete expired recovery: %s, %v", recovery, err)
	}
}

func TestWorkspaceOutputChunksApplyToExactRetainedUTF8(t *testing.T) {
	chunks := []string{}
	replica := []string{}
	var output string
	for _, text := range []string{"a", "🌳", strings.Repeat("é", 250), "abc", "012345", strings.Repeat("δ", 245), strings.Repeat("!", 1200), " 🌅"} {
		oldSize := len(output)
		output += text
		if len(output) > 512 {
			i := len(output) - 512
			for !utf8.RuneStart(output[i]) {
				i++
			}
			output = output[i:]
		}
		var patches []aguiPatch
		chunks, patches = outputPatches("/chunks", chunks, oldSize, text, output)
		for _, p := range patches {
			if p.Path == "/chunks" {
				replica = slices.Clone(p.Value.([]string))
				continue
			}
			where := strings.TrimPrefix(p.Path, "/chunks/")
			if where == "-" {
				replica = append(replica, p.Value.(string))
				continue
			}
			n, err := strconv.Atoi(where)
			if err != nil {
				t.Fatal(err)
			}
			if p.Op == "remove" {
				replica = slices.Delete(replica, n, n+1)
			} else {
				replica[n] = p.Value.(string)
			}
		}
		if strings.Join(replica, "") != output || !slices.Equal(replica, chunks) {
			t.Fatalf("bad tail after %d bytes", len(text))
		}
	}
}

func TestWorkspaceToolPatchesCarryLatestTypedActivity(t *testing.T) {
	w := &Worker{ID: "w", Console: []ConsoleEvent{{Sequence: 1, Kind: "tool_call", ToolID: "call", Name: "Read"}}}
	p := workspaceProjection{incrementalReaders: 1}
	p.rebuild([]*Run{{ID: "r", Workers: []*Worker{w}}})
	before := p.revision
	update := ConsoleEvent{Sequence: 2, Kind: "tool_update", ToolID: "call", Text: "read a file", ACP: &acpprocessor.Activity{Kind: "tool_call_update", Cursor: "opaque.cursor"}}
	w.Console = append(w.Console, update)
	p.updateWorker(w, "", []ConsoleEvent{update})
	frame, _, err := p.next(before, true)
	if err != nil || !bytes.Contains(frame, []byte(`"op":"replace","path":"/runs/0/workers/0/messages/0"`)) || !bytes.Contains(frame, []byte(`"cursor":"opaque.cursor"`)) {
		t.Fatalf("lost typed tool update: %s (%v)", frame, err)
	}
}
