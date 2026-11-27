package provider

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"slices"
	"strconv"
	"sync"
	"sync/atomic"

	model "agent-acp.local/sdks/go/model"
	"agent-acp.local/sdks/go/runtime"
	"agentcommander/internal/acpprocessor"
	"agentcommander/internal/localapi"
	"agentcommander/internal/service"
	acp "github.com/coder/acp-go-sdk"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"
)

type acpSourcePublisher struct {
	v2         *acpV2Inputs
	portable   bool // a compiled adapter can produce SDK observations without an ACP wire peer
	activeTurn atomic.Bool
	queue      *sourceQueue
	mu         sync.Mutex

	// The SDK delivers text and tools as portable summaries. Join richer wire
	// identities by cursor before their live projection. A bounded ring mirrors
	// the pinned SDK's 512-observation window and holds descriptors only.
	references map[string]wireActivity
	order      [512]string
	next       int
	idleWire   *idleWireCursors
}

// A wire update never copies raw tool arguments into its console reference.
type wireActivity struct {
	*acpprocessor.Activity
	toolCallID     string
	commanderInput string
	// detail is for the local app only and never joins the console reference.
	detail *service.ToolDetail
}

// A compiler-provided ACP runtime can offer both a wire callback and an idle
// portable event. Join only matching sessions and cursors.
type sourceRefKey struct {
	session service.NativeSession
	cursor  string
}

type idleWireCursors struct {
	seen  map[sourceRefKey]bool
	order [512]sourceRefKey
	next  int
}

func (p *acpSourcePublisher) rememberIdle(key sourceRefKey) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.idleWire == nil {
		p.idleWire = &idleWireCursors{seen: make(map[sourceRefKey]bool)}
	}
	r := p.idleWire
	delete(r.seen, r.order[r.next])
	r.order[r.next] = key
	r.next = (r.next + 1) % len(r.order)
	r.seen[key] = true
}
func (p *acpSourcePublisher) takeIdle(key sourceRefKey) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.idleWire == nil || !p.idleWire.seen[key] {
		return false
	}
	delete(p.idleWire.seen, key)
	return true
}

func idleKey(session *model.SessionRef, cursor string) sourceRefKey {
	return sourceRefKey{session: service.NativeSession{HarnessInstance: session.GetHarnessInstance(), SessionID: session.GetSessionId()}, cursor: cursor}
}

func sourceReference(wire, portable *acpprocessor.Activity) *acpprocessor.Activity {
	if wire != nil {
		return wire
	}
	return portable
}

// Gap cursors describe an expired boundary and can collide with a previously
// captured event. Keep the unmodified SDK observation under a separate scoped
// identity. A backend may omit a native cursor for this particular signal.
func (p *acpSourcePublisher) captureGap(ctx context.Context, obs *model.Observation) *acpprocessor.Activity {
	var cursor string
	if obs.Cursor != "" {
		hash := sha256.Sum256([]byte(obs.Cursor))
		cursor = "gap-" + hex.EncodeToString(hash[:])
	} else {
		cursor = "gap-" + rand.Text()
	}
	update := service.LiveSourceUpdate{Kind: service.LiveObservationKind, Session: service.NativeSession{HarnessInstance: obs.Session.HarnessInstance, SessionID: obs.Session.SessionId}, Cursor: cursor, TurnID: obs.TurnId}
	raw, err := protojson.Marshal(obs)
	if err != nil {
		update.Gap = "Could not encode the provider gap observation"
	} else {
		update.Body = raw
	}
	if !p.enqueue(ctx, update) {
		return nil
	}
	activity := acpprocessor.Reference("live", cursor, "agentacp.gap", "")
	activity.TurnID = obs.TurnId
	return activity
}

func (p *acpSourcePublisher) showObservationGap(ctx context.Context, screen *screen, event *model.Observation, recoverable bool) {
	activity := p.captureGap(ctx, event)
	message := "Live provider observations expired. Turn delivery may be uncertain. Inspect the scoped source for the provider's report."
	if recoverable {
		message = "Some live provider output expired. Pending requests and turn results were preserved."
	}
	screen.line(message)
	screen.recordEvent(service.ConsoleEvent{Kind: "output", Text: message, ACP: activity})
}

func (p *acpSourcePublisher) captureObservation(ctx context.Context, obs *model.Observation) *acpprocessor.Activity {
	var rich *acpprocessor.Activity
	kind, activityKind, cursor := service.LiveObservationKind, service.LiveObservationKind, obs.Cursor
	// A sourced SDK observation directly addresses its original in the same
	// history. Keep both cursor identities intact for consumers that page it.
	if (obs.SourceRecord != nil || obs.GetSourceCursor() != "") && cursor != "" && len(cursor) <= 256 {
		kind = service.LiveSourcedObservationKind
		if record := obs.GetSourceRecord(); record != nil {
			activityKind = record.GetType()
		} else if ext := obs.GetExtension(); ext != nil {
			activityKind = ext.GetType()
		}
	} else if p.portable {
		// Distinguish a compiled adapter's portable observation from an optional
		// ACP update at the same cursor. The wrapper retains the adapter's cursor.
		sum := sha256.Sum256([]byte(cursor))
		cursor = "sdk-" + hex.EncodeToString(sum[:])
	} else {
		return nil
	}
	if ext := paramsSource(obs); ext.GetType() == runtime.ACPUpdateParamsSource {
		inner, err := acpprocessor.ScopedUpdate(ext.Data, obs.GetSession().GetSessionId())
		if err != nil {
			return nil
		}
		decoded := acpprocessor.Decode(inner)
		rich = decoded.Activity("live", cursor)
	}
	update := service.LiveSourceUpdate{
		Session: service.NativeSession{HarnessInstance: obs.Session.HarnessInstance, SessionID: obs.Session.SessionId},
		Cursor:  cursor, TurnID: obs.TurnId, Kind: kind,
	}
	raw, err := encodeLiveObservation(obs, update.BodyLimit())
	if err != nil {
		update.Gap = "Could not encode the adapter's session observation"
	} else if kind == service.LiveSourcedObservationKind {
		// The Protobuf JSON already encodes the original bytes. Transfer it
		// directly as JSON so the local hop does not base64-encode it again.
		update.Observation = raw
	} else {
		update.Body = raw
	}
	if !p.enqueue(ctx, update) {
		return nil
	}
	ref := rich
	if ref == nil {
		ref = acpprocessor.Reference("live", cursor, activityKind, "")
	}
	ref.TurnID = obs.TurnId
	return ref
}

func encodeLiveObservation(obs *model.Observation, limit int) ([]byte, error) {
	source := paramsSource(obs)
	if source == nil && obs.WireProvenance != nil {
		source = obs.SourceRecord
		if source == nil && obs.GetSourceCursor() == obs.Cursor {
			source = obs.GetExtension()
		}
	}
	// Retain small wire properties even when the base64 payload alone exceeds
	// the HTTP record limit. The SDK's binary retention budget is separate.
	toEncode := obs
	if source != nil && len(source.Data) > limit*3/4 {
		toEncode = omittedSourceObservation(obs, source)
	}
	raw, err := protojson.Marshal(toEncode)
	if err != nil || len(raw) <= limit {
		return raw, err
	}
	// Only an oversized observation needs another serialization. Prefer to
	// retain the correlated ID and the original payload when extras are large.
	if original := toEncode.WireProvenance; original != nil {
		wire := proto.CloneOf(original)
		toEncode = &model.Observation{Session: toEncode.Session, TurnId: toEncode.TurnId, Cursor: toEncode.Cursor,
			SourceCursor: toEncode.SourceCursor, SourceRecord: toEncode.SourceRecord, Event: toEncode.Event, WireProvenance: wire}
		if size := len(wire.AdditionalFieldsJson) + len(wire.AdditionalFieldsJsonBytes); size != 0 {
			wire.OmittedAdditionalFieldsBytes = uint64(size)
			wire.AdditionalFieldsJson, wire.AdditionalFieldsJsonBytes = "", nil
			raw, err = protojson.Marshal(toEncode)
			if err != nil || len(raw) <= limit {
				return raw, err
			}
		}
		if size := len(wire.GetIdJson()) + len(wire.IdJsonBytes); size > limit/2 {
			wire.OmittedIdBytes = uint64(size)
			wire.IdJson, wire.IdJsonBytes = nil, nil
			raw, err = protojson.Marshal(toEncode)
			if err != nil || len(raw) <= limit {
				return raw, err
			}
		}
	}
	if source != nil {
		toEncode = omittedSourceObservation(toEncode, source)
		// A normalized preview can itself be as large as the original value.
		if toEncode.SourceRecord != nil {
			toEncode.Event = &model.Observation_Extension{Extension: toEncode.SourceRecord}
			toEncode.SourceRecord = nil
		}
		return protojson.Marshal(toEncode)
	}
	return raw, err
}

func omittedSourceObservation(obs *model.Observation, source *model.Extension) *model.Observation {
	marker := source
	if source.GetType() != "acp.source_omitted" {
		data, _ := json.Marshal(struct {
			SourceType string `json:"sourceType"`
			Reason     string `json:"reason"`
			ByteCount  int    `json:"byteCount"`
		}{source.Type, "commander_live_record_limit", len(source.Data)})
		marker = &model.Extension{Type: "acp.source_omitted", MediaType: "application/json", Data: data}
	}
	out := &model.Observation{Session: obs.Session, Cursor: obs.Cursor, TurnId: obs.TurnId, SourceCursor: obs.SourceCursor, Event: obs.Event, SourceRecord: marker, WireProvenance: obs.WireProvenance}
	if obs.GetExtension() != nil {
		out.Event = &model.Observation_Extension{Extension: marker}
		out.SourceRecord = nil
	}
	return out
}

func newACPSourcePublisher() *acpSourcePublisher {
	return &acpSourcePublisher{queue: newSourceQueue()}
}

func (p *acpSourcePublisher) capture(source runtime.ACPUpdate) {
	if source.ParamsSize > 0 {
		// The worker's lifetime observation owns this same cursor, including
		// between turns. Avoid storing or serializing the original twice.
		return
	}
	if source.TurnID != "" && ordinaryAssistantChunk(source.Body) {
		return
	}
	if !p.enqueue(nil, service.LiveSourceUpdate{
		Session: service.NativeSession{HarnessInstance: source.Session.GetHarnessInstance(), SessionID: source.Session.GetSessionId()},
		Cursor:  source.Cursor, TurnID: source.TurnID, Body: source.Body,
	}) {
		return
	}
	if source.TurnID == "" && p.portable {
		p.rememberIdle(idleKey(source.Session, source.Cursor))
	}
	if source.TurnID != "" {
		var header struct {
			SessionUpdate, MessageID, ToolCallID, Title, Name string
			RawInput                                          json.RawMessage
		}
		if json.Unmarshal(source.Body, &header) == nil {
			switch header.SessionUpdate {
			case "user_message_chunk", "agent_message_chunk", "tool_call", "tool_call_update":
				ref := acpprocessor.Reference("live", source.Cursor, header.SessionUpdate, header.MessageID)
				ref.TurnID = source.TurnID
				wire := wireActivity{Activity: ref, detail: wireToolDetail(source.Body)}
				if header.ToolCallID != "" && len(header.RawInput) != 0 {
					name := header.Title
					if name == "" {
						name = header.Name
					}
					wire.toolCallID = header.ToolCallID
					wire.commanderInput = service.CommanderToolInput(name, header.RawInput)
				}
				p.remember(wire)
			}
		}
	}
}

func (p *acpSourcePublisher) remember(a wireActivity) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.references == nil {
		p.references = make(map[string]wireActivity)
	}
	delete(p.references, p.order[p.next])
	p.order[p.next] = a.Cursor
	p.next = (p.next + 1) % len(p.order)
	p.references[a.Cursor] = a
}

func (p *acpSourcePublisher) take(cursor string) *acpprocessor.Activity {
	return p.takeWire(cursor).Activity
}

func (p *acpSourcePublisher) takeWire(cursor string) wireActivity {
	p.mu.Lock()
	defer p.mu.Unlock()
	a := p.references[cursor]
	delete(p.references, cursor)
	return a
}

func promptPartCursor(turn string, index int) string {
	return "prompt-" + turn + "-" + strconv.Itoa(index)
}

func (p *acpSourcePublisher) capturePrompt(ctx context.Context, request *model.SendRequest) {
	parts := request.GetParts()
	if len(parts) == 0 {
		return
	}
	ref, turn := request.GetSession(), request.GetOperationId()
	session := service.NativeSession{HarnessInstance: ref.GetHarnessInstance(), SessionID: ref.GetSessionId()}
	if !slices.ContainsFunc(parts, func(part *model.PromptPart) bool {
		return part.GetImage() != nil || part.GetAudio() != nil || part.GetResourceLink() != nil || part.GetResource() != nil
	}) {
		if len(parts) == 1 {
			return
		}
		prompt := acp.PromptRequest{SessionId: acp.SessionId(session.SessionID), Prompt: make([]acp.ContentBlock, 0, len(parts))}
		for _, part := range parts {
			prompt.Prompt = append(prompt.Prompt, acp.TextBlock(part.GetText()))
		}
		body, _ := json.Marshal(prompt)
		p.enqueue(ctx, service.LiveSourceUpdate{
			Session: session, Cursor: "prompt-" + turn, TurnID: turn, Kind: service.LiveTextPromptKind, Body: body,
		})
		return
	}
	// A mixed prompt can have adjacent, empty, or repeated text blocks. Index
	// every block in its original order. Attachment readers select just the media.
	for index, part := range parts {
		kind, media := "image", part.GetImage()
		if media == nil {
			kind, media = "audio", part.GetAudio()
		}
		update := service.LiveSourceUpdate{Session: session, Cursor: promptPartCursor(turn, index), TurnID: turn}
		if part.GetResourceLink() != nil || part.GetResource() != nil {
			block, _, err := runtime.PromptResourceBlock(part, true)
			if err != nil {
				continue
			}
			update.Kind = service.LivePromptMediaPartKind
			update.Body, _ = json.Marshal(block)
		} else if media == nil {
			update.Kind = service.LivePromptTextPartKind
			update.Body, _ = json.Marshal(acp.TextBlock(part.GetText()))
		} else {
			update.Kind = service.LivePromptMediaPartKind
			update.Body, _ = json.Marshal(struct {
				Type     string `json:"type"`
				MIMEType string `json:"mimeType"`
				Data     []byte `json:"data"`
			}{kind, media.GetMimeType(), media.GetData()})
		}
		p.enqueue(ctx, update)
	}
}

// SDK callbacks can arrive during Open, before publishing starts. Only the
// accepted prompt path can wait for capacity. It runs after the worker binds.
func (p *acpSourcePublisher) enqueue(ctx context.Context, update service.LiveSourceUpdate) bool {
	if len(update.Body)+len(update.Observation) > update.BodyLimit() {
		update.Body, update.Observation = nil, nil
		update.Gap = "An ACP source record exceeded the live retention limit"
	}
	return p.queue.put(ctx, update)
}

func ordinaryAssistantChunk(raw json.RawMessage) bool {
	// Common compact ACP output has these two members in declaration order.
	// Decode only the quoted text in that case. A trailing member, nested
	// field, or different order falls through to the general shape check.
	if content, ok := bytes.CutPrefix(raw, []byte(`{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":`)); ok {
		if quoted, ok := bytes.CutSuffix(content, []byte("}}")); ok {
			var text string
			if len(quoted) > 0 && quoted[0] == '"' && json.Unmarshal(quoted, &text) == nil {
				return len(text) <= maxConsoleEventBytes && consoleText(text) == text
			}
		}
	}
	var update map[string]json.RawMessage
	if json.Unmarshal(raw, &update) != nil || len(update) != 2 {
		return false
	}
	var kind string
	if json.Unmarshal(update["sessionUpdate"], &kind) != nil || kind != "agent_message_chunk" {
		return false
	}
	var content map[string]json.RawMessage
	if json.Unmarshal(update["content"], &content) != nil || len(content) != 2 {
		return false
	}
	var text string
	return json.Unmarshal(content["type"], &kind) == nil && kind == "text" &&
		json.Unmarshal(content["text"], &text) == nil && len(text) <= maxConsoleEventBytes && consoleText(text) == text
}

func (p *acpSourcePublisher) publish(ctx context.Context, a *api, path string, ref *model.SessionRef, screen *screen) func() {
	done := make(chan struct{})
	session := service.NativeSession{HarnessInstance: ref.GetHarnessInstance(), SessionID: ref.GetSessionId()}
	p.queue.bind(session)
	go func() {
		defer close(done)
		uploader := sourceUploader{api: a, path: path + "/live-source"}
		batch := make([]service.LiveSourceUpdate, 0, service.LiveSourceBatchRecords)
		for {
			batch = p.queue.get(batch[:0])
			if len(batch) == 0 {
				break
			}
			for _, update := range batch {
				if update.TurnID == "" && update.Kind == "" && len(update.Body) > 0 {
					decoded := acpprocessor.Decode(update.Body)
					event := acpActivityEvent(&decoded, "live", update.Cursor)
					screen.line(event.Text)
					screen.recordEvent(event)
				}
			}
			uploader.deliver(ctx, batch)
			clear(batch)
		}
		uploader.reportLoss(ctx)
	}()
	return func() { p.queue.close(); <-done }
}

// A single writer preserves arrival order. The receiver deduplicates original
// cursors, including when an acknowledgement is lost after committing a batch.
type sourceUploader struct {
	api         *api
	path        string
	singlesOnly bool
	loss        *sourceLoss
}

func (u *sourceUploader) post(ctx context.Context, path string, data any) error {
	return retryOutput(ctx, true, func(call context.Context) error {
		_, err := u.api.client.Do(call, "POST", path, data)
		return err
	})
}

func (u *sourceUploader) reportLoss(ctx context.Context) {
	if loss := u.loss; loss != nil {
		gap := loss.record("could not be uploaded to Commander")
		if u.post(ctx, u.path, gap) == nil {
			u.loss = nil
		}
	}
}

func (u *sourceUploader) deliver(ctx context.Context, batch []service.LiveSourceUpdate) {
	u.reportLoss(ctx)
	if len(batch) > 1 && !u.singlesOnly {
		err := u.post(ctx, u.path+"/batch", batch)
		if err == nil {
			return
		}
		var response *localapi.ResponseError
		if errors.As(err, &response) && (response.StatusCode == 404 || response.StatusCode == 405) {
			u.singlesOnly = true
		}
	}
	// Typed receivers validate a batch atomically. Isolate an invalid record
	// and deliver its valid siblings. Older receivers take the same single route.
	for _, update := range batch {
		if ctx.Err() != nil {
			return
		}
		if u.post(ctx, u.path, update) != nil {
			u.loss = u.loss.add(update)
		}
		if u.loss != nil {
			u.reportLoss(ctx)
		}
	}
}
