package service

// Tool details are what Pretty shows beyond the console preview: full tool
// arguments and results, plan items and times. They are kept apart from
// ConsoleEvent so that no AG-UI snapshot, run record, hosted client or network
// peer carries them. Only the local app reads them.

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"io/fs"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"agentcommander/internal/hosted"
)

const (
	// MaxToolDetailField bounds one argument, result or content value. A longer
	// value is shortened and listed in Truncated, whatever the settings say.
	MaxToolDetailField = 512 << 10
	toolDetailRecords  = 256
	toolDetailBytes    = 16 << 20
	toolDetailBatch    = 128
	toolDetailSummary  = 512
	shortenedMark      = "…[shortened]"
	minTranscriptLimit = 1 << 10
)

// ToolDetail describes one tool call, thought or plan. A runner sends partial
// records; later non-empty values replace earlier ones under the same key.
type ToolDetail struct {
	Key  string `json:"key,omitempty"`
	Kind string `json:"kind"`
	// Event indexes the console event in the same output batch. The service
	// turns it into Sequence and clears it.
	Event     *int            `json:"event,omitempty"`
	Sequence  int             `json:"sequence,omitempty"`
	Name      string          `json:"name,omitempty"`
	Title     string          `json:"title,omitempty"`
	ToolKind  string          `json:"tool_kind,omitempty"`
	Input     string          `json:"input,omitempty"`
	Result    string          `json:"result,omitempty"`
	Content   string          `json:"content,omitempty"`
	Plan      json.RawMessage `json:"plan,omitempty"`
	StartedAt string          `json:"started_at,omitempty"`
	EndedAt   string          `json:"ended_at,omitempty"`
	Truncated []string        `json:"truncated,omitempty"`
	Revision  uint64          `json:"revision,omitempty"`
}

// Size is the record's variable payload, used to bound batches and retention.
func (d *ToolDetail) Size() int {
	return len(d.Key) + len(d.Name) + len(d.Title) + len(d.Input) + len(d.Result) + len(d.Content) + len(d.Plan)
}

// toolDetailSummaryView is the part a closed sentence needs.
type toolDetailSummaryView struct {
	ToolDetail
	// Fields holds the input's short top-level values, in the order sent.
	Fields      json.RawMessage `json:"fields,omitempty"`
	InputBytes  int             `json:"input_bytes,omitempty"`
	ResultBytes int             `json:"result_bytes,omitempty"`
}

// TranscriptSettings controls what new tool details keep. The zero value keeps
// everything as sent.
type TranscriptSettings struct {
	// HideSecrets is applied by the app when it draws a value.
	HideSecrets bool `json:"hide_secrets"`
	// LimitBytes shortens longer values before they are stored. Zero is no limit.
	LimitBytes int `json:"limit_bytes"`
}

type toolDetailLog struct {
	records  map[string]*ToolDetail
	order    []string
	bytes    int
	revision uint64
	written  int
}

// toolDetailStore is guarded by service.mu.
type toolDetailStore struct {
	dir          string
	settingsPath string
	settings     TranscriptSettings
	logs         map[string]*toolDetailLog
}

func (s *toolDetailStore) open(stateDir string) error {
	s.dir = filepath.Join(stateDir, "tool-details")
	s.settingsPath = filepath.Join(stateDir, "transcript-settings.json")
	s.logs = map[string]*toolDetailLog{}
	raw, err := os.ReadFile(s.settingsPath)
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	// A damaged settings file must not silently drop a limit the user chose.
	return json.Unmarshal(raw, &s.settings)
}

func (s *toolDetailStore) path(worker string) string {
	return filepath.Join(s.dir, filepath.Base(worker)+".jsonl")
}

func (s *toolDetailStore) log(worker string) *toolDetailLog {
	if current := s.logs[worker]; current != nil {
		return current
	}
	current := &toolDetailLog{records: map[string]*ToolDetail{}}
	s.logs[worker] = current
	file, err := os.Open(s.path(worker))
	if err != nil {
		return current
	}
	defer file.Close()
	reader := bufio.NewReader(file)
	for {
		line, err := reader.ReadBytes('\n')
		current.written += len(line)
		var record ToolDetail
		// A line cut off by a crash is skipped.
		if err == nil && json.Unmarshal(line, &record) == nil && record.Key != "" {
			current.put(record)
		}
		if err != nil {
			return current
		}
	}
}

// put stores a merged record and drops the oldest ones past the bounds.
func (l *toolDetailLog) put(record ToolDetail) {
	if old := l.records[record.Key]; old != nil {
		l.bytes -= old.Size()
	} else {
		l.order = append(l.order, record.Key)
	}
	l.records[record.Key] = &record
	l.bytes += record.Size()
	l.revision = max(l.revision, record.Revision)
	for len(l.order) > 1 && (len(l.order) > toolDetailRecords || l.bytes > toolDetailBytes) {
		l.bytes -= l.records[l.order[0]].Size()
		delete(l.records, l.order[0])
		l.order = l.order[1:]
	}
}

func mergeToolDetail(old ToolDetail, next ToolDetail) ToolDetail {
	merged := old
	merged.Key, merged.Kind = next.Key, next.Kind
	if merged.Sequence == 0 || next.Kind == "plan" {
		merged.Sequence = next.Sequence
	}
	for _, field := range []struct {
		to   *string
		from string
		name string
	}{
		{&merged.Name, next.Name, ""}, {&merged.Title, next.Title, ""}, {&merged.ToolKind, next.ToolKind, ""},
		{&merged.Input, next.Input, "input"}, {&merged.Result, next.Result, "result"}, {&merged.Content, next.Content, "content"},
	} {
		if field.from == "" {
			continue
		}
		*field.to = field.from
		if field.name == "" {
			continue
		}
		merged.Truncated = slices.DeleteFunc(slices.Clone(merged.Truncated), func(v string) bool { return v == field.name })
		if slices.Contains(next.Truncated, field.name) {
			merged.Truncated = append(merged.Truncated, field.name)
		}
	}
	if len(next.Plan) != 0 {
		merged.Plan = next.Plan
	}
	if merged.StartedAt == "" {
		merged.StartedAt = next.StartedAt
	}
	if next.EndedAt != "" {
		merged.EndedAt = next.EndedAt
	}
	return merged
}

// add stores one batch. A write failure costs detail, never console output.
func (s *toolDetailStore) add(worker string, details []ToolDetail) {
	if len(details) == 0 || s.dir == "" {
		return
	}
	current := s.log(worker)
	var lines bytes.Buffer
	for _, detail := range details {
		var old ToolDetail
		if found := current.records[detail.Key]; found != nil {
			old = *found
		}
		merged := mergeToolDetail(old, detail)
		current.revision++
		merged.Revision = current.revision
		current.put(merged)
		if raw, err := json.Marshal(merged); err == nil {
			lines.Write(append(raw, '\n'))
		}
	}
	if err := s.write(worker, current, lines.Bytes()); err != nil {
		log.Printf("keep tool details for %s: %v", worker, err)
	}
}

func (s *toolDetailStore) write(worker string, current *toolDetailLog, lines []byte) error {
	if err := os.MkdirAll(s.dir, 0700); err != nil {
		return err
	}
	// Updates repeat whole records, so rewrite once stale copies dominate.
	if current.written+len(lines) > 2*toolDetailBytes {
		var all bytes.Buffer
		for _, key := range current.order {
			raw, err := json.Marshal(current.records[key])
			if err != nil {
				return err
			}
			all.Write(append(raw, '\n'))
		}
		temp := s.path(worker) + ".tmp"
		if err := os.WriteFile(temp, all.Bytes(), 0600); err != nil {
			return err
		}
		current.written = all.Len()
		return os.Rename(temp, s.path(worker))
	}
	file, err := os.OpenFile(s.path(worker), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	_, err = file.Write(lines)
	current.written += len(lines)
	return errors.Join(err, file.Close())
}

// prepare bounds runner-supplied details and binds them to console positions.
// events are the batch's events after sequence assignment; offset counts events
// the service inserted before the runner's first one.
func (s *toolDetailStore) prepare(details []ToolDetail, events []ConsoleEvent, offset, last int) []ToolDetail {
	if len(details) > toolDetailBatch {
		details = details[:toolDetailBatch]
	}
	prepared := make([]ToolDetail, 0, len(details))
	latest := time.Now().Add(5 * time.Minute)
	for _, d := range details {
		d.Sequence, d.Revision = last, 0
		// A negative index means before the batch's first event.
		if d.Event != nil && *d.Event >= 0 && *d.Event+offset < len(events) {
			d.Sequence = events[*d.Event+offset].Sequence
		} else if d.Event != nil && *d.Event < 0 && offset < len(events) {
			d.Sequence = events[offset].Sequence - 1
		}
		d.Event = nil
		if d.Kind != "tool" && d.Kind != "thought" && d.Kind != "plan" {
			continue
		}
		if d.Key == "" {
			if d.Sequence == 0 {
				continue
			}
			d.Key = "event-" + strconv.Itoa(d.Sequence)
		}
		if len(d.Key) > 256 {
			continue
		}
		d.Name, d.Title, d.ToolKind = cutText(d.Name, 256), cutText(d.Title, 4096), cutText(d.ToolKind, 64)
		for _, stamp := range []*string{&d.StartedAt, &d.EndedAt} {
			if at, err := time.Parse(time.RFC3339Nano, *stamp); err != nil || at.After(latest) {
				*stamp = ""
			}
		}
		d.Truncated = slices.DeleteFunc(d.Truncated, func(v string) bool { return v != "input" && v != "result" && v != "content" })
		for _, field := range []struct {
			value *string
			name  string
		}{{&d.Input, "input"}, {&d.Result, "result"}, {&d.Content, "content"}} {
			cut := false
			if s.settings.LimitBytes > 0 {
				*field.value, cut = shortenValues(*field.value, s.settings.LimitBytes)
			}
			if len(*field.value) > MaxToolDetailField {
				*field.value, cut = cutText(*field.value, MaxToolDetailField)+shortenedMark, true
			}
			if cut && !slices.Contains(d.Truncated, field.name) {
				d.Truncated = append(d.Truncated, field.name)
			}
		}
		if len(d.Plan) > 64<<10 || (len(d.Plan) != 0 && !json.Valid(d.Plan)) {
			d.Plan = nil
		}
		prepared = append(prepared, d)
	}
	return prepared
}

func cutText(value string, limit int) string {
	if len(value) <= limit {
		return value
	}
	for limit > 0 && !utf8.RuneStart(value[limit]) {
		limit--
	}
	return value[:limit]
}

// shortenValues cuts every string longer than limit. JSON keeps its structure
// and key order, so a shortened record stays readable.
func shortenValues(value string, limit int) (string, bool) {
	if len(value) <= limit {
		return value, false
	}
	trimmed := strings.TrimSpace(value)
	if trimmed != "" && (trimmed[0] == '{' || trimmed[0] == '[') && json.Valid([]byte(trimmed)) {
		decoder := json.NewDecoder(strings.NewReader(trimmed))
		decoder.UseNumber()
		var out bytes.Buffer
		cut := false
		if err := copyJSON(decoder, &out, limit, &cut); err == nil {
			if !cut {
				return value, false
			}
			return out.String(), true
		}
	}
	return cutText(value, limit) + shortenedMark, true
}

func copyJSON(decoder *json.Decoder, out *bytes.Buffer, limit int, cut *bool) error {
	token, err := decoder.Token()
	if err != nil {
		return err
	}
	scalar := func(v any) error {
		if text, ok := v.(string); ok && len(text) > limit {
			v, *cut = cutText(text, limit)+shortenedMark, true
		}
		var raw bytes.Buffer
		encoder := json.NewEncoder(&raw)
		encoder.SetEscapeHTML(false)
		if err := encoder.Encode(v); err != nil {
			return err
		}
		out.Write(bytes.TrimSuffix(raw.Bytes(), []byte("\n")))
		return nil
	}
	open, nested := token.(json.Delim)
	if !nested {
		return scalar(token)
	}
	out.WriteRune(rune(open))
	for first := true; decoder.More(); first = false {
		if !first {
			out.WriteByte(',')
		}
		if open == '{' {
			key, err := decoder.Token()
			if err != nil {
				return err
			}
			name, _ := key.(string)
			raw, err := json.Marshal(name)
			if err != nil {
				return err
			}
			out.Write(raw)
			out.WriteByte(':')
		}
		if err := copyJSON(decoder, out, limit, cut); err != nil {
			return err
		}
	}
	closing, err := decoder.Token()
	if err != nil {
		return err
	}
	delim, ok := closing.(json.Delim)
	if !ok {
		return io.ErrUnexpectedEOF
	}
	out.WriteRune(rune(delim))
	return nil
}

// shortFields returns the input object's short scalar values in their order.
func shortFields(input string) json.RawMessage {
	decoder := json.NewDecoder(strings.NewReader(input))
	decoder.UseNumber()
	if open, err := decoder.Token(); err != nil || open != json.Delim('{') {
		return nil
	}
	var out bytes.Buffer
	out.WriteByte('{')
	for decoder.More() && out.Len() < 8<<10 {
		key, err := decoder.Token()
		name, ok := key.(string)
		var value json.RawMessage
		if err != nil || !ok || decoder.Decode(&value) != nil {
			return nil
		}
		if len(value) == 0 || value[0] == '{' || value[0] == '[' || len(value) > toolDetailSummary {
			continue
		}
		raw, err := json.Marshal(name)
		if err != nil {
			return nil
		}
		if out.Len() > 1 {
			out.WriteByte(',')
		}
		out.Write(raw)
		out.WriteByte(':')
		out.Write(value)
	}
	if out.Len() == 1 {
		return nil
	}
	out.WriteByte('}')
	return out.Bytes()
}

// localOwner reports a request from this machine's owner, never a hosted client
// or a worker credential.
func localOwner(req *http.Request, actor string) bool {
	_, supplied := req.Header["Authorization"]
	return actor == "" && !supplied && hosted.From(req.Context()) == nil
}

// readToolDetails lists summaries changed after a revision, or one full record.
func (s *service) readToolDetails(req *http.Request, actor string) (outcome, error) {
	if !localOwner(req, actor) {
		return outcome{}, denied()
	}
	_, w := s.worker(req.PathValue("worker"))
	if w == nil {
		return outcome{}, missing("worker")
	}
	current := s.details.log(w.ID)
	query := req.URL.Query()
	if key := query.Get("key"); key != "" {
		record := current.records[key]
		if record == nil {
			return outcome{}, missing("tool detail")
		}
		return read(*record), nil
	}
	after, _ := strconv.ParseUint(query.Get("after"), 10, 64)
	records := []toolDetailSummaryView{}
	for _, key := range current.order {
		record := current.records[key]
		if record.Revision <= after {
			continue
		}
		view := toolDetailSummaryView{ToolDetail: *record, Fields: shortFields(record.Input),
			InputBytes: len(record.Input), ResultBytes: len(record.Result)}
		view.Input, view.Result, view.Content = "", "", ""
		records = append(records, view)
	}
	return read(map[string]any{"revision": current.revision, "records": records}), nil
}

func (s *service) readTranscriptSettings(req *http.Request, actor string) (outcome, error) {
	if !localOwner(req, actor) {
		return outcome{}, denied()
	}
	return read(s.details.settings), nil
}

// setTranscriptSettings applies to records stored from now on.
func (s *service) setTranscriptSettings(req *http.Request, actor string) (outcome, error) {
	if !localOwner(req, actor) {
		return outcome{}, denied()
	}
	var input TranscriptSettings
	if err := decode(req, &input); err != nil {
		return outcome{}, err
	}
	if input.LimitBytes != 0 && (input.LimitBytes < minTranscriptLimit || input.LimitBytes > MaxToolDetailField) {
		return outcome{}, bad("limit_bytes must be 0 or between 1024 and 524288")
	}
	raw, err := json.Marshal(input)
	if err != nil {
		return outcome{}, err
	}
	if err := os.WriteFile(s.details.settingsPath, raw, 0600); err != nil {
		return outcome{}, err
	}
	s.details.settings = input
	return read(input), nil
}
