package provider

import (
	"bytes"
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"sync"

	acp "agent-acp.local/sdks/go"
	"agent-acp.local/sdks/go/conformance"
	pb "agent-acp.local/sdks/go/model"
	"agent-acp.local/sdks/go/runtime"
	"agentcommander/harness"
	"google.golang.org/protobuf/proto"
)

// This adapter is compiled only into the provider test binary, including the
// copy which tmux starts as a real runner. It reads an actual workspace file
// on approval and retains the latest completed read under the session ID.
var compiledFixture = harness.Adapter{
	ID: "fixture-reader", Version: "1.0.0",
	Open: func(config runtime.Config) (harness.Runtime, error) {
		if config.Command != "" {
			return nil, fmt.Errorf("compiled fixture unexpectedly received executable %q", config.Command)
		}
		return &fixtureRuntime{config: config, sessions: make(map[string]*fixtureSession)}, nil
	},
	ReadHistory: fixtureReadHistory,
}

var readerScenario = conformance.Scenario{
	Prompt:           "  Read receipt.txt. Preserve $HOME and \"quotes\".\n",
	PermissionPrompt: "Allow reading receipt.txt?", ChoiceLabel: "Allow once",
	ToolResultMarker: "EMBEDDED-492", CompletionMarker: "receipt verified",
	InterruptPrompt: "Wait for a targeted interrupt", InterruptReady: "waiting",
	HistoryMarker: "EMBEDDED-492",
	ExtensionType: "fixture/retained-media", ExtensionDataMarker: "opaque",
}

// This vendor block is larger than the public console preview and includes
// non-text bytes. Only the addressed live source should contain its payload.
var readerMedia = bytes.Repeat([]byte("opaque\x00\xff"), 3000)

func init() {
	if err := harness.Register(compiledFixture); err != nil {
		panic(err)
	}
}

func fixtureReadHistory(_ context.Context, cwd string, req *pb.ReadHistoryRequest) (*pb.ReadHistoryResponse, error) {
	ref := req.GetSession()
	if ref.GetHarnessInstance() != compiledFixtureInstance || !validID.MatchString(ref.GetSessionId()) || req.Cursor != "" {
		return nil, errors.New("unknown fixture history location")
	}
	record, err := os.ReadFile(filepath.Join(cwd, ref.SessionId+".pb"))
	if err != nil {
		return nil, err
	}
	var result pb.Observation
	if err := proto.Unmarshal(record, &result); err != nil {
		return nil, err
	}
	return &pb.ReadHistoryResponse{Observations: []*pb.Observation{&result}}, nil
}

const compiledFixtureInstance = "local-builtin:fixture-reader@1.0.0"

// Unary operations and streaming reads share a lock since the real runner
// continues observing while the user's permission reply is being delivered.
type fixtureRuntime struct {
	config   runtime.Config
	mu       sync.Mutex
	sessions map[string]*fixtureSession
}

type fixtureSession struct {
	ref           *pb.SessionRef
	turn, pending string
	operations    map[string]proto.Message
	events        []*pb.Observation
	changed       chan struct{}
}

func (r *fixtureRuntime) Close() error { return nil }

func (s *fixtureSession) append(event *pb.Observation) {
	event.Session, event.TurnId = s.ref, s.turn
	event.Cursor = s.ref.SessionId + "/" + strconv.Itoa(len(s.events)+1)
	s.events = append(s.events, event)
	close(s.changed)
	s.changed = make(chan struct{})
}

func (s *fixtureSession) say(speaker pb.Speaker, text string) {
	s.append(&pb.Observation{Event: &pb.Observation_Text{Text: &pb.TextUpdate{Speaker: speaker, Text: text}}})
}

func (s *fixtureSession) end(reason string) {
	s.append(&pb.Observation{Event: &pb.Observation_TurnEnded{TurnEnded: &pb.TurnEnded{Reason: reason}}})
	s.turn, s.pending = "", ""
}

func (r *fixtureRuntime) Unary(ctx context.Context, _ string, req, out proto.Message) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	switch q := req.(type) {
	case *pb.OpenRequest:
		if q.HarnessInstance != r.config.HarnessInstance || q.WorkingDirectory != r.config.WorkingDirectory {
			return errors.New("unexpected fixture launch target")
		}
		ref := &pb.SessionRef{HarnessInstance: q.HarnessInstance, SessionId: rand.Text()}
		r.sessions[ref.SessionId] = &fixtureSession{ref: ref, operations: make(map[string]proto.Message), changed: make(chan struct{})}
		out.(*pb.OpenResponse).Session = &pb.Session{Ref: ref, Capabilities: &pb.Capabilities{CanAnswer: true, CanInterrupt: true, CanReadHistory: true}}
		return nil
	case *pb.ReadHistoryRequest:
		page, err := fixtureReadHistory(ctx, r.config.WorkingDirectory, q)
		if err == nil {
			proto.Merge(out, page)
		}
		return err
	}
	command, ok := req.(interface {
		GetSession() *pb.SessionRef
		GetOperationId() string
	})
	if !ok {
		return errors.New("unsupported fixture operation")
	}
	ref, id := command.GetSession(), command.GetOperationId()
	s := r.sessions[ref.GetSessionId()]
	if s == nil || !proto.Equal(s.ref, ref) || id == "" {
		return errors.New("misaddressed fixture operation")
	}
	if prev := s.operations[id]; prev != nil {
		if !proto.Equal(prev, req) {
			return errors.New("different fixture command under existing operation ID")
		}
	} else {
		switch q := req.(type) {
		case *pb.SendRequest:
			for _, part := range q.GetParts() {
				if part.GetImage() != nil || part.GetAudio() != nil {
					return errors.New("fixture does not support image or audio prompts")
				}
			}
			if s.turn != "" {
				return errors.New("fixture is busy")
			}
			s.turn = id
			s.say(pb.Speaker_SPEAKER_USER, q.Text)
			if q.Text == readerScenario.InterruptPrompt {
				s.say(pb.Speaker_SPEAKER_ASSISTANT, readerScenario.InterruptReady)
			} else {
				s.pending = s.ref.SessionId + "/" + id
				s.append(&pb.Observation{Event: &pb.Observation_Input{Input: &pb.InputRequest{
					RequestId: s.pending, Prompt: readerScenario.PermissionPrompt,
					Choices: []*pb.Choice{{Id: "once", Label: readerScenario.ChoiceLabel}},
				}}})
			}
		case *pb.AnswerRequest:
			if q.RequestId != s.pending || s.pending == "" || q.GetOptionId() != "once" {
				return errors.New("unknown fixture request or choice")
			}
			raw, err := os.ReadFile(filepath.Join(r.config.WorkingDirectory, "receipt.txt"))
			if err != nil {
				return err
			}
			result := &pb.Observation{Event: &pb.Observation_Tool{Tool: &pb.ToolActivity{
				CallId: "read-" + s.turn, Name: "Read receipt.txt", Phase: "completed", Summary: string(raw),
			}}}
			s.append(result)
			record, err := proto.Marshal(result)
			if err != nil {
				return err
			}
			if err := os.WriteFile(filepath.Join(r.config.WorkingDirectory, s.ref.SessionId+".pb"), record, 0600); err != nil {
				return err
			}
			s.append(&pb.Observation{Event: &pb.Observation_Extension{Extension: &pb.Extension{
				Type: readerScenario.ExtensionType, MediaType: "application/octet-stream", Data: readerMedia,
			}}})
			s.say(pb.Speaker_SPEAKER_ASSISTANT, readerScenario.CompletionMarker)
			s.end("end_turn")
		case *pb.InterruptRequest:
			if q.TurnId != s.turn || s.turn == "" {
				return errors.New("stale fixture interrupt")
			}
			s.end("cancelled")
		}
		s.operations[id] = proto.Clone(req)
	}
	receipt := &pb.Receipt{OperationId: id, Status: pb.DeliveryStatus_DELIVERY_STATUS_DELIVERED}
	switch v := out.(type) {
	case *pb.SendResponse:
		v.Receipt = receipt
	case *pb.AnswerResponse:
		v.Receipt = receipt
	case *pb.InterruptResponse:
		v.Receipt = receipt
	default:
		return errors.New("unsupported fixture response")
	}
	return nil
}

type fixtureReader struct {
	ctx  context.Context
	r    *fixtureRuntime
	s    *fixtureSession
	next int
}

func (r *fixtureRuntime) Stream(ctx context.Context, op string, req proto.Message) (acp.Stream, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	q, ok := req.(*pb.ObserveRequest)
	if !ok || op != "Observe" {
		return nil, errors.New("unsupported fixture stream")
	}
	s := r.sessions[q.GetSession().GetSessionId()]
	if s == nil || !proto.Equal(s.ref, q.Session) {
		return nil, errors.New("unknown fixture session")
	}
	reader := &fixtureReader{ctx: ctx, r: r, s: s}
	if q.AfterCursor != "" {
		i := slices.IndexFunc(s.events, func(e *pb.Observation) bool { return e.Cursor == q.AfterCursor })
		if i < 0 {
			return nil, errors.New("unknown fixture cursor")
		}
		reader.next = i + 1
	}
	return reader, nil
}

func (f *fixtureReader) Close() {}

func (f *fixtureReader) Recv(out proto.Message) error {
	for {
		f.r.mu.Lock()
		if f.next < len(f.s.events) {
			event := f.s.events[f.next]
			f.next++
			f.r.mu.Unlock()
			proto.Merge(out, event)
			return nil
		}
		changed := f.s.changed
		f.r.mu.Unlock()
		select {
		case <-f.ctx.Done():
			return f.ctx.Err()
		case <-changed:
		}
	}
}
