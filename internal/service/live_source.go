package service

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"strconv"
	"strings"

	model "agent-acp.local/sdks/go/model"
	"agent-acp.local/sdks/go/runtime"
	"agentcommander/internal/acpprocessor"
	"google.golang.org/protobuf/encoding/protojson"
)

// LiveSourceUpdate is data supplied by the scoped runner for its one bound ACP
// session. Raw bytes never enter the workspace output or the persisted run.
type LiveSourceUpdate struct {
	Session     NativeSession   `json:"session"`
	Cursor      string          `json:"cursor,omitempty"`
	TurnID      string          `json:"turn_id,omitempty"`
	Kind        string          `json:"kind,omitempty"`
	Body        []byte          `json:"body,omitempty"`
	Gap         string          `json:"gap,omitempty"`
	Observation json.RawMessage `json:"observation,omitempty"`

	observation *model.Observation
	encodedSize int
}

const (
	LiveTextPromptKind         = "acp.session_prompt"
	LivePromptMediaPartKind    = "acp.prompt_part"
	LivePromptTextPartKind     = "acp.prompt_text"
	LiveObservationKind        = "agentacp.observation"
	LiveSourcedObservationKind = "agentacp.sourced_observation"
	MaxLiveSourceRecord        = 720 << 10
	liveSourcePageBytes        = 2560 << 10
	LiveSourceWindowBytes      = 4 << 20
	liveSourceTotalBytes       = 32 << 20
	liveSourceWindowCount      = 64
	LiveSourceWindowRecords    = 256
	LiveSourceBatchRecords     = 16
)

func (u LiveSourceUpdate) BodyLimit() int {
	// The run endpoint accepts a 1 MiB JSON prompt. A single media part may
	// occupy nearly all of it, and the SDK envelope base64-encodes it again.
	if u.Kind == LivePromptMediaPartKind || u.Kind == LivePromptTextPartKind || u.Kind == LiveTextPromptKind {
		return 1 << 20
	}
	return MaxLiveSourceRecord
}

type liveSourceStore struct {
	windows map[string]*liveSourceWindow
	tick    uint64
	bytes   int
}

type liveSourceWindow struct {
	epoch   string
	touched uint64
	removed uint64
	bytes   int
	records []LiveSourceUpdate
	cursors map[string]struct{}
}

func (s *service) recordLiveSource(req *http.Request, actor string) (outcome, error) {
	_, worker, err := s.own(req, actor)
	if err != nil {
		return outcome{}, err
	}
	var update LiveSourceUpdate
	if err := decode(req, &update); err != nil {
		return outcome{}, err
	}
	if err := update.prepare(worker.NativeSession); err != nil {
		return outcome{}, err
	}
	s.liveSource.append(worker.ID, update)
	return read(map[string]string{"id": worker.ID}), nil
}

func (s *service) recordLiveSourceBatch(req *http.Request, actor string) (outcome, error) {
	_, worker, err := s.own(req, actor)
	if err != nil {
		return outcome{}, err
	}
	raw, _ := req.Context().Value(bodyKey{}).([]byte)
	dec := json.NewDecoder(bytes.NewReader(raw))
	open, err := dec.Token()
	if err != nil || open != json.Delim('[') {
		return outcome{}, bad("expected an array of ACP source records")
	}
	// Decode at most sixteen values even if a bounded HTTP request contains
	// thousands of tiny JSON objects. Publish only after validating all of them.
	var updates [LiveSourceBatchRecords]LiveSourceUpdate
	count := 0
	for dec.More() {
		if count == len(updates) {
			return outcome{}, bad("too many ACP source records in a batch")
		}
		update := &updates[count]
		if err := dec.Decode(update); err != nil {
			return outcome{}, bad("invalid ACP source record in batch")
		}
		if update.Cursor == "" {
			return outcome{}, bad("batch source record must have a cursor")
		}
		if err := update.prepare(worker.NativeSession); err != nil {
			return outcome{}, err
		}
		count++
	}
	end, err := dec.Token()
	if err != nil || end != json.Delim(']') || count == 0 {
		return outcome{}, bad("invalid or empty ACP source batch")
	}
	if _, err := dec.Token(); err != io.EOF {
		return outcome{}, bad("unexpected data after ACP source batch")
	}
	for i := range count {
		s.liveSource.append(worker.ID, updates[i])
	}
	return read(map[string]string{"id": worker.ID}), nil
}

func (update *LiveSourceUpdate) prepare(bound *NativeSession) error {
	if bound == nil || *bound != update.Session {
		return conflict("ACP source does not match the bound worker session")
	}
	size := len(update.Body) + len(update.Observation)
	if (update.Kind != "" && update.Kind != LivePromptMediaPartKind && update.Kind != LivePromptTextPartKind && update.Kind != LiveTextPromptKind &&
		update.Kind != LiveObservationKind && update.Kind != LiveSourcedObservationKind) ||
		len(update.TurnID) > 256 || len(update.Cursor) > 256 || len(update.Gap) > 256 ||
		size > update.BodyLimit() || (size != 0) == (update.Gap != "") ||
		(size > 0 && update.Cursor == "") || (len(update.Observation) > 0 && update.Kind != LiveSourcedObservationKind) {
		return bad("invalid ACP source observation")
	}
	if len(update.Body) != 0 && (update.Kind == LiveSourcedObservationKind || !json.Valid(update.Body)) {
		return bad("invalid ACP source update body or cursor")
	}
	if update.Kind == LiveObservationKind && strings.HasPrefix(update.Cursor, "gap-") && len(update.Body) > 0 {
		var gap model.Observation
		if protojson.Unmarshal(update.Body, &gap) != nil || gap.GetGap() == nil || gap.GetSession().GetSessionId() != bound.SessionID ||
			gap.GetSession().GetHarnessInstance() != bound.HarnessInstance || gap.GetTurnId() != update.TurnID {
			return bad("gap observation does not match its selected session")
		}
	}
	if len(update.Observation) > 0 {
		var observation model.Observation
		if err := protojson.Unmarshal(update.Observation, &observation); err != nil || observation.Event == nil ||
			observation.GetSession().GetSessionId() != update.Session.SessionID ||
			observation.GetSession().GetHarnessInstance() != update.Session.HarnessInstance ||
			observation.TurnId != update.TurnID || observation.Cursor != update.Cursor ||
			(observation.SourceRecord == nil && observation.GetSourceCursor() == "") {
			return bad("source observation does not match the bound record")
		}
		for _, ext := range []*model.Extension{observation.GetSourceRecord(), observation.GetExtension()} {
			if ext.GetType() == runtime.ACPUpdateParamsSource {
				if observation.GetSourceCursor() != observation.Cursor || ext.GetMediaType() != "application/json" {
					return bad("invalid sourced ACP params")
				}
				if _, err := acpprocessor.ScopedUpdate(ext.Data, bound.SessionID); err != nil {
					return bad("invalid or cross-session ACP params")
				}
			}
		}
		// Keep one immutable copy of the original bytes. Either source reader can
		// render this SDK observation with its normal typed fields and source record.
		update.observation, update.encodedSize, update.Observation = &observation, size, nil
	}
	return nil
}

func (s *liveSourceStore) append(worker string, update LiveSourceUpdate) {
	if s.windows == nil {
		s.windows = make(map[string]*liveSourceWindow)
	}
	w := s.windows[worker]
	if w == nil {
		w = &liveSourceWindow{epoch: randomID("live-"), cursors: make(map[string]struct{})}
		s.windows[worker] = w
	}
	if update.Cursor != "" {
		if _, retained := w.cursors[update.Cursor]; retained {
			return
		}
		w.cursors[update.Cursor] = struct{}{}
	}
	s.tick++
	w.touched = s.tick
	// Charge metadata as well as raw bytes so the global bound also limits
	// short records and gaps.
	size := update.historySize()
	w.records = append(w.records, update)
	w.bytes += size
	s.bytes += size
	for len(w.records) > LiveSourceWindowRecords || w.bytes > LiveSourceWindowBytes {
		oldest := &w.records[0]
		size := oldest.historySize()
		delete(w.cursors, oldest.Cursor)
		w.records[0] = LiveSourceUpdate{}
		w.records = w.records[1:]
		w.removed++
		w.bytes -= size
		s.bytes -= size
	}
	for len(s.windows) > liveSourceWindowCount || s.bytes > liveSourceTotalBytes {
		var oldestID string
		var oldest *liveSourceWindow
		for id, window := range s.windows {
			if oldest == nil || window.touched < oldest.touched {
				oldestID, oldest = id, window
			}
		}
		s.bytes -= oldest.bytes
		delete(s.windows, oldestID)
	}
}

// RetainedSize charges metadata and source bytes identically on both sides of the local API.
func (update LiveSourceUpdate) RetainedSize() int {
	return 192 + len(update.Session.HarnessInstance) + len(update.Session.SessionID) +
		len(update.Body) + len(update.Observation) + update.encodedSize + len(update.Gap) + len(update.TurnID) + len(update.Cursor) + len(update.Kind)
}

func (update LiveSourceUpdate) historySize() int {
	size := update.RetainedSize()
	if update.Cursor != "" {
		// The history index shares the record's cursor bytes. Charge its
		// string header and map slot only in the store that owns that index.
		size += 32
	}
	return size
}

func (s *liveSourceStore) page(worker string, ref NativeSession, turnID, kind, cursor string, limit int) (*model.ReadHistoryResponse, error) {
	session := &model.SessionRef{HarnessInstance: ref.HarnessInstance, SessionId: ref.SessionID}
	page := &model.ReadHistoryResponse{}
	addGap := func(reason string) {
		page.Observations = append(page.Observations, &model.Observation{
			Session: session, Event: &model.Observation_Gap{Gap: &model.HistoryGap{Reason: reason}},
		})
	}
	w := s.windows[worker]
	var after uint64
	turnSuffix := ""
	if turnID != "" {
		turnSuffix = "." + base64.RawURLEncoding.EncodeToString([]byte(turnID))
	}
	if kind != "" {
		turnSuffix += "." + base64.RawURLEncoding.EncodeToString([]byte(kind))
	}
	if cursor != "" {
		scope, remainder, _ := strings.Cut(cursor, ".")
		epoch, offset, ok := strings.Cut(remainder, ".")
		var err error
		position, sameTurn := strings.CutSuffix(offset, turnSuffix)
		after, err = strconv.ParseUint(position, 10, 64)
		if scope != worker || !ok || epoch == "" || !sameTurn || err != nil {
			return nil, bad("invalid cursor for this live ACP source selection")
		}
		if w != nil && epoch != w.epoch {
			addGap("The previous live ACP source window is no longer available")
			after = w.removed
		}
	}
	if w == nil {
		addGap("No live ACP source records are retained for this session")
		return page, nil
	}
	if after < w.removed {
		addGap("Earlier live ACP source records expired from the retained window")
		after = w.removed
	}
	end := w.removed + uint64(len(w.records))
	if after > end {
		return nil, bad("live ACP source cursor is ahead of the retained window")
	}
	var pageBytes int
	for after < end {
		record := w.records[after-w.removed]
		if turnID != "" && record.TurnID != turnID && (record.Gap == "" || record.TurnID != "") {
			after++
			continue
		}
		if kind != "" && record.Kind != kind && record.Gap == "" {
			after++
			continue
		}
		if len(page.Observations) >= limit || pageBytes >= liveSourcePageBytes {
			break
		}
		observation := &model.Observation{Session: session, Cursor: record.Cursor, TurnId: record.TurnID}
		if record.Gap != "" {
			observation.Event = &model.Observation_Gap{Gap: &model.HistoryGap{Reason: record.Gap}}
		} else if record.observation != nil {
			observation = record.observation
		} else {
			kind := record.Kind
			if kind == "" {
				kind = "acp.session_update"
			}
			observation.Event = &model.Observation_Extension{Extension: &model.Extension{
				Type: kind, MediaType: "application/json", Data: record.Body,
			}}
		}
		page.Observations = append(page.Observations, observation)
		pageBytes += len(record.Body) + record.encodedSize
		after++
	}
	if after < end {
		page.NextCursor = worker + "." + w.epoch + "." + strconv.FormatUint(after, 10) + turnSuffix
	}
	if turnID != "" && cursor == "" && len(page.Observations) == 0 {
		if kind != "" {
			addGap("No prompt attachments are retained for this turn")
		} else {
			addGap("No live ACP source records are retained for this turn")
		}
	}
	return page, nil
}
