package actions

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"
)

type workspaceHandoffRecord struct {
	ID           string    `json:"id"`
	Peer         string    `json:"peer"`
	GrantGroup   string    `json:"grantGroup,omitempty"`
	Resource     string    `json:"resource"`
	Workspace    string    `json:"workspace"`
	Anchor       string    `json:"anchor"`
	Title        string    `json:"title"`
	Text         string    `json:"text"`
	ExpectedHead string    `json:"expectedHead,omitempty"`
	Approval     string    `json:"approval"`
	ExpiresAt    time.Time `json:"expiresAt"`
	DeliveredAt  time.Time `json:"deliveredAt"`
	Observation  workspaceHandoffObservation
}

type workspaceHandoffObservation struct {
	Run        string     `json:"run,omitempty"`
	State      string     `json:"state"`
	AcceptedAt *time.Time `json:"acceptedAt,omitempty"`
	VerifiedAt *time.Time `json:"verifiedAt,omitempty"`
	Failure    string     `json:"failure,omitempty"`
	Head       string     `json:"head,omitempty"`
}

func workspaceStore(cfg Config) string {
	return filepath.Join(cfg.StateDir, "workspace-handoffs")
}

func workspaceHandoff(cfg Config, r Resource, req Request) (json.RawMessage, error) {
	switch req.Action {
	case "agent.handoff":
		var in struct {
			Title        string        `json:"title"`
			Task         string        `json:"task"`
			Context      []ContextItem `json:"context"`
			ExpectedHead string        `json:"expectedHead,omitempty"`
		}
		if strict(req.Payload, &in) != nil || len(in.Title) > 200 || strings.TrimSpace(in.Title) == "" ||
			strings.TrimSpace(in.Task) == "" || len(in.Task) > 15360 || !validContext(in.Context) ||
			(in.ExpectedHead != "" && !oid.MatchString(in.ExpectedHead)) || req.Deadline.IsZero() {
			return nil, ErrInvalid
		}
		text := "[Workspace handoff from " + req.Peer + ", shared operation " + req.ID + "]\n" + in.Task + renderContext(in.Context)
		if len(text) > 116<<10 {
			return nil, ErrInvalid
		}
		grant, ok := activeGrant(cfg, req)
		if !ok {
			return nil, ErrDenied
		}
		approval := "pending"
		if grant.Approval == "auto" {
			approval = "auto"
		}
		row := workspaceHandoffRecord{
			ID: req.ID, Peer: req.Peer, GrantGroup: req.Group, Resource: r.ID, Workspace: r.Workspace, Anchor: r.Target,
			Title: in.Title, Text: text, ExpectedHead: in.ExpectedHead, Approval: approval, ExpiresAt: req.Deadline.UTC(),
		}
		record, err := storeWorkspaceHandoff(cfg, row)
		if err != nil {
			return nil, err
		}
		// The transport receipt always describes delivery. Newer observations
		// are fetched separately; receipt replay never advances a milestone.
		return answer(map[string]any{"run": record.ID, "title": record.Title, "state": "delivered", "deliveredAt": record.DeliveredAt})
	case "agent.status", "agent.result":
		var in struct {
			Run string `json:"run"`
		}
		if strict(req.Payload, &in) != nil || !identifier.MatchString(in.Run) {
			return nil, ErrInvalid
		}
		record, _, err := loadWorkspaceHandoff(cfg, in.Run)
		if err != nil || record.Peer != req.Peer || record.Resource != r.ID ||
			record.Workspace != r.Workspace || record.Anchor != r.Target {
			return nil, ErrDenied
		}
		return answer(struct {
			workspaceHandoffObservation
			Run         string    `json:"run"`
			Title       string    `json:"title"`
			DeliveredAt time.Time `json:"deliveredAt"`
		}{record.Observation, record.ID, record.Title, record.DeliveredAt})
	}
	return nil, ErrDenied
}

func storeWorkspaceHandoff(cfg Config, candidate workspaceHandoffRecord) (workspaceHandoffRecord, error) {
	dir := workspaceStore(cfg)
	pending := filepath.Join(dir, "pending")
	if err := privateDir(dir); err != nil {
		return candidate, ErrUnavailable
	}
	if err := privateDir(pending); err != nil {
		return candidate, ErrUnavailable
	}
	// The device action reservation is durable, but a helper exit between the
	// workspace write and its action receipt can replay this same delivery.
	lock, err := lockWorkspaceStore(cfg)
	if err != nil {
		return candidate, err
	}
	defer lock.Close()
	existing, _, err := loadWorkspaceHandoff(cfg, candidate.ID)
	if err == nil {
		if existing.Peer != candidate.Peer || existing.GrantGroup != candidate.GrantGroup ||
			existing.Resource != candidate.Resource || existing.Workspace != candidate.Workspace ||
			existing.Anchor != candidate.Anchor || existing.Title != candidate.Title ||
			existing.Text != candidate.Text || existing.ExpectedHead != candidate.ExpectedHead ||
			!existing.ExpiresAt.Equal(candidate.ExpiresAt) {
			return candidate, ErrConflict
		}
		return existing, nil
	}
	if !errors.Is(err, os.ErrNotExist) {
		return candidate, ErrUnavailable
	}
	files, err := os.ReadDir(pending)
	if err != nil || len(files) >= 512 {
		return candidate, ErrUnavailable
	}
	candidate.DeliveredAt = time.Now().UTC()
	candidate.Observation.State = "delivered"
	if err = save(filepath.Join(pending, candidate.ID+".json"), candidate); err != nil {
		return candidate, ErrUncertain
	}
	return candidate, nil
}

func loadWorkspaceHandoff(cfg Config, id string) (workspaceHandoffRecord, string, error) {
	var record workspaceHandoffRecord
	root := workspaceStore(cfg)
	path := filepath.Join(root, id+".json")
	file, err := os.Open(path)
	if errors.Is(err, os.ErrNotExist) {
		path = filepath.Join(root, "pending", id+".json")
		file, err = os.Open(path)
	}
	if err != nil {
		return record, "", err
	}
	defer file.Close()
	err = json.NewDecoder(io.LimitReader(file, 256<<10)).Decode(&record)
	if err == nil && (record.ID != id || !identifier.MatchString(record.Resource) || record.DeliveredAt.IsZero()) {
		err = ErrInvalid
	}
	return record, path, err
}

func lockWorkspaceStore(cfg Config) (*os.File, error) {
	lock, err := os.OpenFile(filepath.Join(workspaceStore(cfg), ".write-lock"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	if err = syscall.Flock(int(lock.Fd()), syscall.LOCK_EX); err != nil {
		_ = lock.Close()
		return nil, err
	}
	return lock, nil
}

type WorkspaceApproval struct {
	ID, Peer, Resource, Title string
	DeliveredAt, ExpiresAt    time.Time
}

// PendingWorkspaceApprovals is the workspace inbox's owner decision queue.
func PendingWorkspaceApprovals(cfg Config) []WorkspaceApproval {
	pending := filepath.Join(workspaceStore(cfg), "pending")
	files, err := os.ReadDir(pending)
	if err != nil {
		return nil
	}
	var approvals []WorkspaceApproval
	for _, file := range files {
		id, ok := strings.CutSuffix(file.Name(), ".json")
		if !ok || !identifier.MatchString(id) || !file.Type().IsRegular() {
			continue
		}
		record, path, err := loadWorkspaceHandoff(cfg, id)
		if err == nil && filepath.Dir(path) == pending && record.Approval == "pending" &&
			time.Now().Before(record.ExpiresAt) {
			approvals = append(approvals, WorkspaceApproval{id, record.Peer, record.Resource, record.Title, record.DeliveredAt, record.ExpiresAt})
		}
	}
	return approvals
}

// ResolveWorkspaceApproval handles only pending decisions in the current owner's
// store. A device restart cannot turn an unresolved request into an approval.
func ResolveWorkspaceApproval(cfg Config, id string, approved bool) (found bool, err error) {
	if !identifier.MatchString(id) {
		return false, nil
	}
	_, _, err = loadWorkspaceHandoff(cfg, id)
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return true, err
	}
	lock, err := lockWorkspaceStore(cfg)
	if err != nil {
		return true, err
	}
	defer lock.Close()
	record, path, err := loadWorkspaceHandoff(cfg, id)
	if err != nil {
		return true, err
	}
	if record.Approval != "pending" || !time.Now().Before(record.ExpiresAt) ||
		filepath.Dir(path) != filepath.Join(workspaceStore(cfg), "pending") {
		return true, ErrDenied
	}
	if approved {
		record.Approval = "approved"
		return true, save(path, record)
	}
	record.Approval = "denied"
	record.Observation = workspaceHandoffObservation{State: "declined", Failure: "workspace_handoff_declined"}
	archive := filepath.Join(workspaceStore(cfg), id+".json")
	if err := save(archive, record); err != nil {
		return true, err
	}
	_ = os.Remove(path)
	return true, nil
}

type WorkspaceAdmission func(context.Context, string) (allowed bool, err error)

// ProcessWorkspaceHandoffs advances already delivered work independently of the
// receive loop. authorize rechecks lease, current workspace membership and grant.
func ProcessWorkspaceHandoffs(ctx context.Context, cfg Config, authorize WorkspaceAdmission) {
	pending := filepath.Join(workspaceStore(cfg), "pending")
	files, err := os.ReadDir(pending)
	if err != nil || len(files) == 0 {
		return
	}
	client, err := commanderClient(cfg.CommanderSocket)
	if err != nil {
		return
	}
	defer client.CloseIdleConnections()
	queue := make([]workspaceHandoffRecord, 0, len(files))
	for _, file := range files {
		id, ok := strings.CutSuffix(file.Name(), ".json")
		if !ok || !identifier.MatchString(id) || !file.Type().IsRegular() {
			continue
		}
		record, path, err := loadWorkspaceHandoff(cfg, id)
		if err == nil && filepath.Dir(path) == pending &&
			(record.Approval != "pending" || !time.Now().Before(record.ExpiresAt)) {
			queue = append(queue, record)
		}
	}
	sort.SliceStable(queue, func(i, j int) bool { return queue[i].DeliveredAt.Before(queue[j].DeliveredAt) })
	busy := make(map[string]bool)
	for _, record := range queue {
		if ctx.Err() != nil {
			return
		}
		if busy[record.Workspace] {
			continue
		}
		path := filepath.Join(pending, record.ID+".json")
		probe, cancel := context.WithTimeout(ctx, 2*time.Second)
		observation, terminal := advanceWorkspaceHandoff(probe, cfg, client, record, authorize)
		cancel()
		if observation == nil {
			busy[record.Workspace] = true
			continue
		}
		record.Observation = *observation
		if terminal {
			finalPath := filepath.Join(workspaceStore(cfg), record.ID+".json")
			if save(finalPath, record) == nil {
				_ = os.Remove(path) // A replay after either write sees the same operation ID.
			}
		} else {
			busy[record.Workspace] = true
			_ = save(path, record)
		}
	}
}

func terminalWorkspaceHandoff(state string) bool {
	switch state {
	case "verified", "unverified", "completed", "failed", "cancelled", "uncertain":
		return true
	default:
		return false
	}
}

func advanceWorkspaceHandoff(ctx context.Context, cfg Config, client *http.Client, r workspaceHandoffRecord, authorize WorkspaceAdmission) (*workspaceHandoffObservation, bool) {
	target := "http://commander/v1/network/workspace-handoffs/" + url.PathEscape(r.ID)
	// First look up any local reservation. A lost POST response, or a relay
	// restart after accepting the handoff, must never launch it again.
	observation, status := callWorkspaceHandoff(ctx, client, http.MethodGet, target, nil)
	if status == http.StatusOK {
		if observation.AcceptedAt != nil && observation.AcceptedAt.Before(r.DeliveredAt) ||
			observation.VerifiedAt != nil && (observation.AcceptedAt == nil || observation.VerifiedAt.Before(*observation.AcceptedAt)) {
			return nil, false
		}
		return observation, terminalWorkspaceHandoff(observation.State)
	}
	if status != http.StatusNotFound {
		return nil, false
	}
	if !time.Now().Before(r.ExpiresAt) {
		return &workspaceHandoffObservation{State: "expired", Failure: "workspace_handoff_expired"}, true
	}
	var current Resource
	for _, resource := range cfg.Resources {
		if resource.ID == r.Resource && resource.Workspace == r.Workspace && resource.Target == r.Anchor {
			current = resource
			break
		}
	}
	if current.ID == "" {
		return &workspaceHandoffObservation{State: "denied", Failure: "workspace_handoff_revoked"}, true
	}
	grant, granted := activeGrant(cfg, Request{Peer: r.Peer, Group: r.GrantGroup, Resource: r.Resource, Action: "agent.handoff"})
	if !granted {
		// The policy snapshot can temporarily be unavailable after reconnect.
		// Ask the authoritative admission endpoint before finalizing a denial.
		allowed, err := authorize(ctx, r.ID)
		if err != nil || allowed {
			return nil, false
		}
		return &workspaceHandoffObservation{State: "denied", Failure: "workspace_handoff_revoked"}, true
	}
	allowed, err := authorize(ctx, r.ID)
	if err != nil {
		return nil, false
	}
	if !allowed {
		return &workspaceHandoffObservation{State: "denied", Failure: "workspace_handoff_revoked"}, true
	}
	if r.Approval == "auto" && grant.Approval != "auto" {
		// The current owner policy may now require a person. Queue that
		// decision before scheduling; the Delivered milestone is unchanged.
		path := filepath.Join(workspaceStore(cfg), "pending", r.ID+".json")
		r.Approval = "pending"
		_ = save(path, r)
		return nil, false
	}
	body, _ := json.Marshal(map[string]any{"workspace": r.Workspace, "anchor": r.Anchor, "title": r.Title, "text": r.Text,
		"autoStart": current.AutoStart, "expectedHead": r.ExpectedHead, "expiresAt": r.ExpiresAt})
	observation, status = callWorkspaceHandoff(ctx, client, http.MethodPost, target, body)
	if status/100 == 2 {
		return observation, terminalWorkspaceHandoff(observation.State)
	}
	if status == http.StatusBadRequest || status == http.StatusForbidden {
		return &workspaceHandoffObservation{State: "failed", Failure: "workspace_handler_rejected"}, true
	}
	return nil, false
}

func callWorkspaceHandoff(ctx context.Context, client *http.Client, method, target string, data []byte) (*workspaceHandoffObservation, int) {
	req, err := http.NewRequestWithContext(ctx, method, target, bytes.NewReader(data))
	if err != nil {
		return nil, 0
	}
	if method == http.MethodPost {
		req.Header.Set("Content-Type", "application/json")
	}
	response, err := client.Do(req)
	if err != nil {
		return nil, 0
	}
	defer response.Body.Close()
	if response.StatusCode/100 != 2 {
		return nil, response.StatusCode
	}
	var observation workspaceHandoffObservation
	if json.NewDecoder(io.LimitReader(response.Body, 64<<10)).Decode(&observation) != nil || observation.State == "" {
		return nil, 0
	}
	return &observation, response.StatusCode
}
