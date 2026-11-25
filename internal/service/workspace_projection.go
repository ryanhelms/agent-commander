package service

import (
	"bytes"
	"encoding/json"
	"fmt"
	"reflect"
	"slices"
	"strconv"
	"unicode/utf8"
)

// The private workspace feed has a single visibility scope. Every reader at a
// revision can reuse the same immutable bytes, including during socket writes.
type workspaceProjection struct {
	readers, incrementalReaders int
	revision, structureRevision uint64
	runs                        []*workspaceRun
	workers                     map[string]*workspaceWorker
	frames                      []workspaceFrame
	frameBytes                  int
	legacy                      workspaceFrame
	snapshots                   [2][]byte
	err                         error
}

type workspaceFrame struct {
	after, revision uint64
	data            []byte
}

type workspaceRun struct {
	id         string
	attributes json.RawMessage
	workers    []*workspaceWorker
	changed    uint64
	encoded    [2]json.RawMessage
}

type workspaceWorker struct {
	run            *workspaceRun
	path           string
	attributes     json.RawMessage
	output         string
	telemetry      *WorkerTelemetry
	claudeProgress *ClaudeProgress
	chunks         []string
	events         []ConsoleEvent
	messages       []aguiMessage
	plain          bool
	encoded        [2]json.RawMessage
}

func projectionIndex(incremental bool) int {
	if incremental {
		return 1
	}
	return 0
}

func (p *workspaceProjection) encode(v any) json.RawMessage {
	b, err := json.Marshal(v)
	if err != nil {
		p.err = err
	}
	return b
}

// Attributes are generated from the service's ordinary wire structs. The feed
// owns the output and message fields, and encodes each child independently.
func (p *workspaceProjection) workerAttributes(w *Worker) json.RawMessage {
	return p.encode(struct {
		*Worker
		Output  string         `json:"output,omitempty"`
		Console []ConsoleEvent `json:"console,omitempty"`
	}{Worker: w})
}

func (p *workspaceProjection) runAttributes(r *Run) json.RawMessage {
	return p.encode(struct {
		*Run
		Workers  []*Worker   `json:"workers,omitempty"`
		Requests []*Question `json:"requests"`
	}{Run: r, Requests: append([]*Question{}, r.Requests...)})
}

func (p *workspaceProjection) encodeWorker(w *workspaceWorker, incremental bool) json.RawMessage {
	idx := projectionIndex(incremental)
	if w.encoded[idx] != nil {
		return w.encoded[idx]
	}
	if len(w.attributes) == 0 {
		return nil
	}
	raw := append([]byte(nil), w.attributes[:len(w.attributes)-1]...)
	if incremental {
		raw = append(raw, `,"outputChunks":`...)
		raw = append(raw, p.encode(w.chunks)...)
	} else {
		raw = append(raw, `,"output":`...)
		raw = append(raw, p.encode(w.output)...)
	}
	if incremental || len(w.messages) > 0 {
		raw = append(raw, `,"messages":`...)
		if len(w.messages) == 0 {
			raw = append(raw, "[]"...)
		} else {
			raw = append(raw, p.encode(w.messages)...)
		}
	}
	w.encoded[idx] = append(raw, '}')
	return w.encoded[idx]
}

func (p *workspaceProjection) encodeRun(r *workspaceRun, incremental bool) json.RawMessage {
	idx := projectionIndex(incremental)
	if r.encoded[idx] != nil {
		return r.encoded[idx]
	}
	if len(r.attributes) == 0 {
		return nil
	}
	raw := append([]byte(nil), r.attributes[:len(r.attributes)-1]...)
	raw = append(raw, `,"workers":[`...)
	for i, w := range r.workers {
		if i > 0 {
			raw = append(raw, ',')
		}
		raw = append(raw, p.encodeWorker(w, incremental)...)
	}
	r.encoded[idx] = append(raw, ']', '}')
	return r.encoded[idx]
}

func (p *workspaceProjection) snapshot(incremental, expired bool) ([]byte, error) {
	idx := projectionIndex(incremental)
	if !expired && p.snapshots[idx] != nil {
		return p.snapshots[idx], p.err
	}
	raw := []byte(`data: {"type":"STATE_SNAPSHOT",`)
	if expired {
		raw = append(raw, `"metadata":{"commander":{"reason":"workspace_delta_expired"}},`...)
	}
	raw = append(raw, `"snapshot":{"runs":[`...)
	for i, r := range p.runs {
		if i > 0 {
			raw = append(raw, ',')
		}
		raw = append(raw, p.encodeRun(r, incremental)...)
	}
	raw = append(raw, "]}}\n\n"...)
	if !expired {
		p.snapshots[idx] = raw
	}
	return raw, p.err
}

func splitOutput(text string) []string {
	chunks := []string{}
	for len(text) > 0 {
		n := min(256, len(text))
		for n < len(text) && !utf8.RuneStart(text[n]) {
			n--
		}
		chunks = append(chunks, text[:n])
		text = text[n:]
	}
	return chunks
}

func attributePatches(path string, old, next json.RawMessage) []aguiPatch {
	var before, after map[string]json.RawMessage
	// Both objects were encoded from our own typed state.
	_ = json.Unmarshal(old, &before)
	_ = json.Unmarshal(next, &after)
	var changes []aguiPatch
	for key := range before {
		if _, ok := after[key]; !ok {
			changes = append(changes, aguiPatch{"remove", path + "/" + key, nil})
		}
	}
	for key, value := range after {
		previous, ok := before[key]
		if bytes.Equal(previous, value) {
			continue
		}
		op := "replace"
		if !ok {
			op = "add"
		}
		changes = append(changes, aguiPatch{op, path + "/" + key, value})
	}
	return changes
}

// Reconciliations can replace a retained history or correct earlier fields.
// Preserve common chunks on either side of the changed range.
func reconcileChunks(path string, old, next []string) []aguiPatch {
	first := 0
	for first < len(old) && first < len(next) && old[first] == next[first] {
		first++
	}
	endOld, endNext := len(old), len(next)
	for endOld > first && endNext > first && old[endOld-1] == next[endNext-1] {
		endOld--
		endNext--
	}
	var delta []aguiPatch
	i := first
	for ; i < endOld && i < endNext; i++ {
		delta = append(delta, aguiPatch{"replace", path + "/" + strconv.Itoa(i), next[i]})
	}
	for j := i; j < endOld; j++ {
		delta = append(delta, aguiPatch{"remove", path + "/" + strconv.Itoa(i), nil})
	}
	for ; i < endNext; i++ {
		delta = append(delta, aguiPatch{"add", path + "/" + strconv.Itoa(i), next[i]})
	}
	return delta
}

func (p *workspaceProjection) reconcileWorker(v *workspaceWorker, w *Worker, initial bool) ([]aguiPatch, bool) {
	attrs := p.workerAttributes(w)
	var delta []aguiPatch
	changed := initial
	if !bytes.Equal(attrs, v.attributes) {
		if !initial && p.incrementalReaders > 0 {
			delta = append(delta, attributePatches(v.path, v.attributes, attrs)...)
		}
		v.attributes = attrs
		changed = true
	}
	v.telemetry, v.claudeProgress = w.Telemetry, w.ClaudeProgress
	if initial || w.Output != v.output {
		next := splitOutput(w.Output)
		if !initial && p.incrementalReaders > 0 {
			delta = append(delta, reconcileChunks(v.path+"/outputChunks", v.chunks, next)...)
		}
		v.chunks, v.output = next, w.Output
		changed = true
	}
	if initial || !slices.Equal(w.Console, v.events) {
		next := aguiMessages(w.ID, w.Console)
		if !initial && p.incrementalReaders > 0 {
			delta = append(delta, messagePatches(v.path+"/messages", v.messages, next)...)
		}
		v.messages, v.events, v.plain = next, w.Console, plainConsole(w.Console)
		changed = true
	}
	if changed {
		v.encoded = [2]json.RawMessage{}
	}
	return delta, changed
}

// Run and worker positions are append-only in the Commander store.
func (p *workspaceProjection) rebuild(runs []*Run) {
	initializing := p.workers == nil
	if initializing {
		p.workers = make(map[string]*workspaceWorker)
	}
	p.err = nil
	changed := initializing
	var patches []aguiPatch
	for i, r := range runs {
		path := "/runs/" + strconv.Itoa(i)
		newRun := i == len(p.runs)
		if newRun {
			p.runs = append(p.runs, &workspaceRun{id: r.ID})
			p.structureRevision = p.revision + 1
		}
		item := p.runs[i]
		attributes := p.runAttributes(r)
		runChanged := newRun || !bytes.Equal(item.attributes, attributes)
		if !newRun && runChanged && p.incrementalReaders > 0 {
			patches = append(patches, attributePatches(path, item.attributes, attributes)...)
		}
		item.attributes = attributes
		for j, w := range r.Workers {
			newWorker := j == len(item.workers)
			if newWorker {
				item.workers = append(item.workers, &workspaceWorker{run: item, path: path + "/workers/" + strconv.Itoa(j)})
			}
			v := item.workers[j]
			workerDelta, dirty := p.reconcileWorker(v, w, newWorker)
			if dirty {
				runChanged = true
				if !newRun && p.incrementalReaders > 0 {
					if newWorker {
						patches = append(patches, aguiPatch{"add", path + "/workers/-", p.encodeWorker(v, true)})
					} else {
						patches = append(patches, workerDelta...)
					}
				}
			}
			p.workers[w.ID] = v
		}
		if runChanged {
			changed = true
			item.changed = p.revision + 1
			item.encoded = [2]json.RawMessage{}
			if newRun && !initializing && p.incrementalReaders > 0 {
				patches = append(patches, aguiPatch{"add", "/runs/-", p.encodeRun(item, true)})
			}
		}
	}
	if changed {
		p.commit(patches)
	}
}

func plainConsole(events []ConsoleEvent) bool {
	for _, e := range events {
		if e.ACP != nil && e.ACP.MessageOp != "" {
			return false
		}
		switch e.Kind {
		case "text", "user", "output":
		default:
			return false
		}
	}
	return true
}

func (p *workspaceProjection) updateWorker(w *Worker, appended string, events []ConsoleEvent) {
	v := p.workers[w.ID]
	if v == nil {
		return
	} // a structural commit publishes membership before output is accepted
	var patches []aguiPatch
	if v.output != w.Output || appended != "" {
		v.chunks, patches = outputPatches(v.path+"/outputChunks", v.chunks, len(v.output), appended, w.Output)
		v.output = w.Output
	}
	if v.telemetry != w.Telemetry || v.claudeProgress != w.ClaudeProgress {
		attrs := p.workerAttributes(w)
		if p.incrementalReaders > 0 {
			patches = append(patches, attributePatches(v.path, v.attributes, attrs)...)
		}
		v.telemetry, v.claudeProgress, v.attributes = w.Telemetry, w.ClaudeProgress, attrs
	}
	if len(events) > 0 {
		var next []aguiMessage
		if v.plain && plainConsole(events) && len(w.Console) > 0 {
			first := w.Console[0].Sequence
			keep := 0
			for keep < len(v.messages) && v.messages[keep].sequence < first {
				keep++
			}
			for len(events) > 0 && events[0].Sequence < first {
				events = events[1:]
			}
			next = append(v.messages[keep:], aguiMessages(w.ID, events)...)
		} else {
			next = aguiMessages(w.ID, w.Console)
			v.plain = plainConsole(w.Console)
		}
		if p.incrementalReaders > 0 {
			patches = append(patches, messagePatches(v.path+"/messages", v.messages, next)...)
		}
		v.messages = next
	}
	v.events = w.Console
	v.encoded = [2]json.RawMessage{}
	v.run.encoded = [2]json.RawMessage{}
	v.run.changed = p.revision + 1
	p.commit(patches)
}

// The scalar terminal tail is bounded by bytes and trimmed on UTF-8 boundaries
// by ingestion. The negotiated schema exposes the same string in chunks so
// JSON Patch can append and retire its changed edges.
func outputPatches(path string, chunks []string, oldSize int, added, retained string) ([]string, []aguiPatch) {
	trim := oldSize + len(added) - len(retained)
	if trim < 0 || trim >= oldSize && oldSize > 0 || len(added) > len(retained) {
		next := []string{}
		if retained != "" {
			next = append(next, retained)
		}
		return next, []aguiPatch{{"replace", path, next}}
	}
	var patches []aguiPatch
	for trim > 0 && len(chunks) > 0 {
		if trim < len(chunks[0]) {
			chunks[0] = chunks[0][trim:]
			patches = append(patches, aguiPatch{"replace", path + "/0", chunks[0]})
			break
		}
		trim -= len(chunks[0])
		chunks[0] = ""
		chunks = chunks[1:]
		patches = append(patches, aguiPatch{"remove", path + "/0", nil})
	}
	if added != "" {
		// Bound chunk metadata for one-byte writes while leaving bulk appends intact.
		last := len(chunks) - 1
		if last >= 0 && len(chunks[last])+len(added) <= 256 {
			chunks[last] += added
			patches = append(patches, aguiPatch{"replace", path + "/" + strconv.Itoa(last), chunks[last]})
		} else {
			chunks = append(chunks, added)
			patches = append(patches, aguiPatch{"add", path + "/-", added})
		}
	}
	return chunks, patches
}

func equalMessage(a, b aguiMessage) bool {
	if a.ID != b.ID || a.Role != b.Role || a.ToolCallID != b.ToolCallID || a.Error != b.Error || !slices.Equal(a.ToolCalls, b.ToolCalls) {
		return false
	}
	if a.Content != b.Content && (a.Content == nil || b.Content == nil || *a.Content != *b.Content) {
		return false
	}
	return a.Metadata == b.Metadata || reflect.DeepEqual(a.Metadata, b.Metadata)
}

func messagePatches(path string, old, next []aguiMessage) []aguiPatch {
	var delta []aguiPatch
	for i, j := 0, 0; i < len(old) || j < len(next); {
		if i < len(old) && (j == len(next) || old[i].sequence < next[j].sequence) {
			delta = append(delta, aguiPatch{"remove", path + "/" + strconv.Itoa(j), nil})
			i++
		} else if j < len(next) && (i == len(old) || next[j].sequence < old[i].sequence) {
			at := "-"
			if i < len(old) {
				at = strconv.Itoa(j)
			}
			delta = append(delta, aguiPatch{"add", path + "/" + at, next[j]})
			j++
		} else {
			if !equalMessage(old[i], next[j]) {
				delta = append(delta, aguiPatch{"replace", path + "/" + strconv.Itoa(j), next[j]})
			}
			i++
			j++
		}
	}
	return delta
}

func (p *workspaceProjection) deltaFrame(patches []aguiPatch) []byte {
	if len(patches) == 0 {
		return nil
	}
	raw := p.encode(aguiStateEvent{Type: "STATE_DELTA", Delta: patches})
	frame := append([]byte("data: "), raw...)
	return append(frame, '\n', '\n')
}

func (p *workspaceProjection) commit(patches []aguiPatch) {
	p.revision++
	p.snapshots = [2][]byte{}
	p.legacy = workspaceFrame{}
	if p.incrementalReaders == 0 {
		return
	}
	data := p.deltaFrame(patches)
	p.frames = append(p.frames, workspaceFrame{after: p.revision - 1, revision: p.revision, data: data})
	p.frameBytes += len(data)
	for len(p.frames) > 64 || p.frameBytes > 4<<20 {
		p.frameBytes -= len(p.frames[0].data)
		p.frames[0] = workspaceFrame{}
		p.frames = p.frames[1:]
	}
}

func (p *workspaceProjection) next(after uint64, incremental bool) ([]byte, uint64, error) {
	if after == p.revision || p.err != nil {
		return nil, after, p.err
	}
	if incremental {
		if len(p.frames) > 0 && after >= p.frames[0].after {
			f := p.frames[after-p.frames[0].after]
			return f.data, f.revision, p.err
		}
		b, err := p.snapshot(true, true)
		return b, p.revision, err
	}
	if p.legacy.after == after && p.legacy.revision == p.revision {
		return p.legacy.data, p.revision, p.err
	}
	var patches []aguiPatch
	if after < p.structureRevision {
		values := make([]json.RawMessage, len(p.runs))
		for i, r := range p.runs {
			values[i] = p.encodeRun(r, false)
		}
		patches = []aguiPatch{{"replace", "/runs", values}}
	} else {
		for i, r := range p.runs {
			if r.changed > after {
				patches = append(patches, aguiPatch{"replace", fmt.Sprintf("/runs/%d", i), p.encodeRun(r, false)})
			}
		}
	}
	frame := p.deltaFrame(patches)
	p.legacy = workspaceFrame{after, p.revision, frame}
	return frame, p.revision, p.err
}
