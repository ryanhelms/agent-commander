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
	"maps"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"agentcommander/internal/hosted"
)

const (
	// MaxToolDetailField bounds one argument, result or content value. A longer
	// value is shortened and listed in Truncated, whatever the settings say.
	MaxToolDetailField = 512 << 10
	// MaxToolDetailRecords bounds retained records per worker.
	MaxToolDetailRecords = 256
	toolDetailBytes      = 16 << 20
	toolDetailBatch      = 128
	toolDetailSummary    = 512
	shortenedMark        = "…[shortened]"
	minTranscriptLimit   = 1 << 10
	// A value's shortened paths are kept only while they fit these bounds.
	maxShortenedPaths     = 64
	maxShortenedPathBytes = 4 << 10
)

// ToolDetail describes a local transcript detail. A runner sends partial
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
	// Shortened says where the service cut each value listed in Truncated:
	// JSON Pointers (RFC 6901) to the strings it shortened inside the stored
	// JSON, or one empty pointer when it cut the end off the whole value. A
	// value listed in Truncated with no entry here was cut somewhere unrecorded:
	// by a runner, by an older service, or in more places than the bounds keep.
	// Only the service writes it.
	Shortened map[string][]string `json:"shortened,omitempty"`
	// A nil location leaves an earlier value alone. An explicit empty location
	// clears it, so an ambiguous provider update cannot keep an old target.
	Location *ToolLocation `json:"location,omitempty"`
	Revision uint64        `json:"revision,omitempty"`
	*JobDetail
	*TurnEndDetail
}

// ToolLocation is the single file and line an ACP tool reported for its call.
type ToolLocation struct {
	Path string `json:"path"`
	Line int    `json:"line"`
}

func (l ToolLocation) Valid() bool {
	return l.Line > 0 && uint64(l.Line) <= 1<<32-1 && len(l.Path) <= 4096 &&
		filepath.IsAbs(l.Path) && !strings.ContainsFunc(l.Path, unicode.IsControl)
}

// JobDetail is a snapshot. Empty open-tool fields clear the previous call.
type JobDetail struct {
	ToolUseID    string `json:"tool_use_id"`
	JobKind      string `json:"job_kind"`
	State        string `json:"state"`
	OpenToolName string `json:"open_tool_name,omitempty"`
	OpenToolArg  string `json:"open_tool_arg,omitempty"`
}

type TurnEndDetail struct {
	DurationMS     *int64 `json:"duration_ms,omitempty"`
	StopReason     string `json:"stop_reason,omitempty"`
	TerminalReason string `json:"terminal_reason,omitempty"`
	IsError        *bool  `json:"is_error,omitempty"`
}

// Size is the record's variable payload, used to bound batches and retention.
func (d *ToolDetail) Size() int {
	size := 0
	if l := d.Location; l != nil {
		size += len(l.Path) + 8
	}
	if j := d.JobDetail; j != nil {
		size += len(j.ToolUseID) + len(j.JobKind) + len(j.State) + len(j.OpenToolName) + len(j.OpenToolArg)
	}
	if t := d.TurnEndDetail; t != nil {
		size += len(t.StopReason) + len(t.TerminalReason) + 16
	}
	for name, paths := range d.Shortened {
		size += len(name)
		for _, path := range paths {
			size += len(path) + 1
		}
	}
	return size + len(d.Key) + len(d.Name) + len(d.Title) + len(d.Input) + len(d.Result) + len(d.Content) + len(d.Plan)
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
	for len(l.order) > 1 && (len(l.order) > MaxToolDetailRecords || l.bytes > toolDetailBytes) {
		l.bytes -= l.records[l.order[0]].Size()
		delete(l.records, l.order[0])
		l.order = l.order[1:]
	}
}

func mergeToolDetail(old ToolDetail, next ToolDetail) ToolDetail {
	merged := old
	merged.Key, merged.Kind = next.Key, next.Kind
	merged.JobDetail, merged.TurnEndDetail = next.JobDetail, next.TurnEndDetail
	// The stored record shares old's map, so changes go to a copy.
	merged.Shortened = maps.Clone(old.Shortened)
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
		// A replaced value takes its own paths, or none: the old ones point
		// into text that is gone.
		delete(merged.Shortened, field.name)
		if paths := next.Shortened[field.name]; len(paths) != 0 && slices.Contains(next.Truncated, field.name) {
			if merged.Shortened == nil {
				merged.Shortened = map[string][]string{}
			}
			merged.Shortened[field.name] = paths
		}
	}
	if len(merged.Shortened) == 0 {
		merged.Shortened = nil
	}
	if len(next.Plan) != 0 {
		merged.Plan = next.Plan
	}
	if next.Kind != "tool" || next.Location != nil {
		merged.Location = nil
		if next.Kind == "tool" && next.Location != nil && next.Location.Valid() {
			merged.Location = next.Location
		}
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
		switch d.Kind {
		case "job":
			j := d.JobDetail
			if j == nil || j.ToolUseID == "" || len(j.ToolUseID) > 256 || (j.JobKind != "command" && j.JobKind != "agent") {
				continue
			}
			j.OpenToolName, j.OpenToolArg = cutText(j.OpenToolName, 256), cutText(j.OpenToolArg, toolDetailSummary)
			switch j.State {
			case "running", "completed", "failed", "stopped", "unknown":
			default:
				continue
			}
			d.TurnEndDetail = nil
		case "turn_end":
			d.JobDetail = nil
			if t := d.TurnEndDetail; t != nil {
				t.StopReason, t.TerminalReason = cutText(t.StopReason, 256), cutText(t.TerminalReason, 256)
			}
		case "tool", "thought", "plan":
			d.JobDetail, d.TurnEndDetail = nil, nil
		default:
			continue
		}
		if d.Kind != "tool" {
			d.Location = nil
		} else if d.Location != nil && !d.Location.Valid() {
			d.Location = &ToolLocation{}
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
		// Paths are the service's own account of its cuts, never a runner's.
		d.Shortened = nil
		for _, field := range []struct {
			value *string
			name  string
		}{{&d.Input, "input"}, {&d.Result, "result"}, {&d.Content, "content"}} {
			cut := false
			var paths []string
			if s.settings.LimitBytes > 0 {
				*field.value, paths, cut = shortenValues(*field.value, s.settings.LimitBytes)
			}
			if len(*field.value) > MaxToolDetailField {
				// The end of the whole value goes, and any earlier path with it.
				*field.value, paths, cut = cutText(*field.value, MaxToolDetailField)+shortenedMark, []string{""}, true
			}
			if cut && !slices.Contains(d.Truncated, field.name) {
				d.Truncated = append(d.Truncated, field.name)
			}
			if cut && len(paths) != 0 {
				if d.Shortened == nil {
					d.Shortened = map[string][]string{}
				}
				d.Shortened[field.name] = paths
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
// and key order, so a shortened record stays readable. paths names what was
// cut: a JSON Pointer to each shortened string, or one empty pointer when the
// end of the whole value was cut. It is nil when the cuts pass the bounds.
func shortenValues(value string, limit int) (string, []string, bool) {
	if len(value) <= limit {
		return value, nil, false
	}
	trimmed := strings.TrimSpace(value)
	if trimmed != "" && (trimmed[0] == '{' || trimmed[0] == '[') && json.Valid([]byte(trimmed)) {
		decoder := json.NewDecoder(strings.NewReader(trimmed))
		decoder.UseNumber()
		var out bytes.Buffer
		cuts := shortenedPaths{}
		if err := copyJSON(decoder, &out, limit, "", &cuts); err == nil {
			if cuts.count == 0 {
				return value, nil, false
			}
			return out.String(), cuts.kept(), true
		}
	}
	return cutText(value, limit) + shortenedMark, []string{""}, true
}

// shortenedPaths collects the pointers of one value's cut strings.
type shortenedPaths struct {
	paths     []string
	count     int
	bytes     int
	ambiguous bool
}

func (c *shortenedPaths) fits() bool {
	return !c.ambiguous && c.count <= maxShortenedPaths && c.bytes <= maxShortenedPathBytes
}

func (c *shortenedPaths) add(path string) {
	c.count++
	c.bytes += len(path)
	if c.fits() {
		c.paths = append(c.paths, path)
	} else {
		// Every path is kept, or none: a partial list would pass for a whole one.
		c.paths = nil
	}
}

func (c *shortenedPaths) kept() []string {
	if !c.fits() {
		return nil
	}
	return c.paths
}

var pointerEscape = strings.NewReplacer("~", "~0", "/", "~1")

func copyJSON(decoder *json.Decoder, out *bytes.Buffer, limit int, path string, cuts *shortenedPaths) error {
	token, err := decoder.Token()
	if err != nil {
		return err
	}
	scalar := func(v any) error {
		if text, ok := v.(string); ok && len(text) > limit {
			v = cutText(text, limit) + shortenedMark
			cuts.add(path)
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
	// Past the bounds no path is kept, so none is built either.
	tracked := func() bool { return cuts.fits() && len(path) <= maxShortenedPathBytes }
	var seen map[string]struct{}
	if open == '{' && tracked() {
		seen = make(map[string]struct{})
	}
	for index := 0; decoder.More(); index++ {
		if index > 0 {
			out.WriteByte(',')
		}
		child := path
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
			if tracked() {
				if _, duplicate := seen[name]; duplicate {
					// A JSON Pointer cannot address one of two members with the same name.
					cuts.ambiguous, cuts.paths = true, nil
				} else {
					seen[name] = struct{}{}
					child = path + "/" + pointerEscape.Replace(name)
				}
			}
		} else if tracked() {
			child = path + "/" + strconv.Itoa(index)
		}
		if err := copyJSON(decoder, out, limit, child, cuts); err != nil {
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
		view.Input, view.Result, view.Content, view.Shortened = "", "", "", nil
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
