// Package actions executes an authenticated child's named action against an owner-local grant.
package actions

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"syscall"
	"time"

	"agentcommander.network/pilot/internal/sharing"
)

type Resource struct {
	ID           string                `json:"id"`
	Name         string                `json:"name"`
	Kind         string                `json:"kind"`
	Target       string                `json:"target"`
	Branch       string                `json:"branch,omitempty"`
	Repository   string                `json:"repository,omitempty"`
	Base         string                `json:"base,omitempty"`
	Run          string                `json:"run,omitempty"`
	Coordinator  bool                  `json:"coordinator,omitempty"`
	Capabilities *sharing.Capabilities `json:"capabilities,omitempty"`
}
type Grant struct {
	ID string `json:"id,omitempty"`
	// UsageID identifies this issuance across policy edits. Revocation retires it.
	UsageID   string    `json:"usageId,omitempty"`
	Peer      string    `json:"peer"`
	Group     string    `json:"group,omitempty"`
	Resource  string    `json:"resource"`
	Action    string    `json:"action"`
	ExpiresAt time.Time `json:"expiresAt"`
	MaxUses   int       `json:"maxUses,omitempty"`
	// Approval defaults to "ask". "auto" runs initiating actions within limits.
	Approval     string `json:"approval,omitempty"`
	BudgetTokens int    `json:"budgetTokens,omitempty"`
	Attribution  string `json:"attribution,omitempty"`
}
type Request struct {
	ID       string          `json:"id"`
	Peer     string          `json:"peer"`
	Group    string          `json:"group,omitempty"`
	Resource string          `json:"resource"`
	Action   string          `json:"action"`
	Payload  json.RawMessage `json:"payload"`
}
type Config struct {
	StateDir, CommanderSocket string
	Resources                 []Resource
	Grants                    []Grant
	// ReceivedRequest also recognizes initiating requests still awaiting a decision.
	ReceivedRequest func(peer, resource, request string) bool
	// GitHubToken selects a credential for this specific resource ID and capability.
	GitHubToken func(context.Context, string, string) (string, error)
	testGitHub  string
	testPushURL string
}

var (
	identifier         = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._:@-]{0,127}$`)
	ErrDenied          = errors.New("action is outside the current local grant")
	ErrBudgetExhausted = errors.New("grant token budget exhausted")
	ErrInvalid         = errors.New("invalid action or target")
	ErrUncertain       = errors.New("outcome uncertain; reconcile the original operation")
	ErrConflict        = errors.New("operation identity or expected revision conflicts")
	ErrStaleRevision   = fmt.Errorf("shared revision changed: %w", ErrConflict)
	ErrUnavailable     = errors.New("owner-local resource or credential unavailable")
)

var actionFailures = [...]struct {
	err  error
	code string
}{
	{ErrStaleRevision, "stale_revision"},
	{ErrConflict, "conflict"},
	{ErrDenied, "access_denied"},
	{ErrBudgetExhausted, "budget_exhausted"},
	{ErrInvalid, "invalid_request"},
	{ErrUnavailable, "resource_unavailable"},
	{ErrUncertain, "outcome_uncertain"},
}

// FailureCode translates owner-local failures into the fixed vocabulary peers see.
func FailureCode(err error) string {
	for _, failure := range actionFailures {
		if errors.Is(err, failure.err) {
			return failure.code
		}
	}
	return "resource_unavailable"
}

// A descriptor is a compiled device-side capability, independent of the broker.
// Registration is package-owned. Grant documents may select names but cannot install handlers.
type handler func(context.Context, Config, Resource, Request, string, bool) (json.RawMessage, error)
type descriptor struct {
	kind, name, description, payloadSchema string
	recoverable                            bool
	run                                    handler
}

func register(entries ...descriptor) map[string]descriptor {
	bank := make(map[string]descriptor, len(entries))
	for _, entry := range entries {
		if entry.kind == "" || entry.name == "" || entry.run == nil || bank[entry.name].run != nil ||
			entry.description == "" || !json.Valid([]byte(entry.payloadSchema)) {
			panic("invalid device action registration")
		}
		bank[entry.name] = entry
	}
	return bank
}
func repoHandler(ctx context.Context, cfg Config, r Resource, req Request, _ string, _ bool) (json.RawMessage, error) {
	return repoAction(ctx, cfg, r, req.Action, req.Payload)
}
func issueHandler(ctx context.Context, cfg Config, r Resource, req Request, _ string, _ bool) (json.RawMessage, error) {
	return issueAction(ctx, cfg, r, req.Action, req.Payload)
}
func agentHandler(ctx context.Context, cfg Config, r Resource, req Request, id string, recoverOnly bool) (json.RawMessage, error) {
	return ask(ctx, cfg, r, id, req.Payload, recoverOnly)
}

func registeredKind(r Resource) string {
	switch r.Kind {
	case "repo":
		return "repo"
	case "host":
		return "host"
	case "agent":
		if !r.Coordinator {
			return "agent"
		}
		if identifier.MatchString(r.Run) {
			return "coordinator"
		}
	}
	return ""
}

// ResourceCapabilities advertises only actions for the enrolled local target.
func ResourceCapabilities(r Resource) []string { return Capabilities(registeredKind(r)) }

func Capabilities(kind string) []string {
	var names []string
	for _, entry := range registry {
		if entry.kind == kind {
			names = append(names, entry.name)
		}
	}
	sort.Strings(names)
	return names
}
func hash(data []byte) string { h := sha256.Sum256(data); return hex.EncodeToString(h[:]) }
func strict(raw []byte, v any) error {
	d := json.NewDecoder(bytes.NewReader(raw))
	d.DisallowUnknownFields()
	if err := d.Decode(v); err != nil {
		return ErrInvalid
	}
	var extra any
	if !errors.Is(d.Decode(&extra), io.EOF) {
		return ErrInvalid
	}
	return nil
}
func answer(v any) (json.RawMessage, error) { b, e := json.Marshal(v); return b, e }

type receipt struct {
	Digest   string          `json:"digest"`
	Grant    string          `json:"grant"`
	Resource string          `json:"resource,omitempty"`
	Action   string          `json:"action,omitempty"`
	Status   string          `json:"status"`
	Result   json.RawMessage `json:"result,omitempty"`
	Failure  string          `json:"failure,omitempty"`
}

func privateDir(path string) error {
	if !filepath.IsAbs(path) {
		return ErrInvalid
	}
	if err := os.MkdirAll(path, 0700); err != nil {
		return err
	}
	info, err := os.Lstat(path)
	if err != nil || !info.IsDir() || info.Mode().Perm()&0077 != 0 {
		return ErrUnavailable
	}
	return nil
}
func save(path string, v any) error {
	dir := filepath.Dir(path)
	f, err := os.CreateTemp(dir, ".next-*")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if err = json.NewEncoder(f).Encode(v); err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	if err = os.Rename(f.Name(), path); err != nil {
		return err
	}
	parent, err := os.Open(dir)
	if err != nil {
		return err
	}
	defer parent.Close()
	return parent.Sync()
}
func load(path string) (receipt, error) {
	var r receipt
	f, e := os.Open(path)
	if e != nil {
		return r, e
	}
	defer f.Close()
	e = json.NewDecoder(io.LimitReader(f, 256<<10)).Decode(&r)
	return r, e
}

// reserve serializes admissions only. A process death after reservation never causes
// another mutating call. Completed results remain retrievable while access is authorized.
func reserve(dir, path, digest string, grant Grant) (receipt, bool, error) {
	lock, e := os.OpenFile(filepath.Join(dir, ".lock"), os.O_RDWR|os.O_CREATE, 0600)
	if e != nil {
		return receipt{}, false, e
	}
	defer lock.Close()
	if e = syscall.Flock(int(lock.Fd()), syscall.LOCK_EX); e != nil {
		return receipt{}, false, e
	}
	r, e := load(path)
	if e == nil {
		if r.Digest != digest {
			return r, false, ErrConflict
		}
		return r, false, nil
	}
	if !errors.Is(e, os.ErrNotExist) {
		return receipt{}, false, e
	}
	if err := checkLimits(dir, grant); err != nil {
		return receipt{}, false, err
	}
	r = receipt{Digest: digest, Grant: grant.ReceiptKey(), Resource: grant.Resource, Action: grant.Action, Status: "started"}
	return r, true, save(path, r)
}

// IsFollowUp identifies actions whose handler must verify the initiating request.
func IsFollowUp(action string) bool {
	switch action {
	case "agent.status", "agent.result", "thread.read", "thread.comment":
		return true
	}
	return false
}

// ReceiptKey preserves existing receipts for grants issued by older devices.
func (g Grant) ReceiptKey() string {
	if g.UsageID != "" {
		return g.UsageID
	}
	key, _ := json.Marshal([]any{g.ID, g.Peer, g.Resource, g.Action, g.ExpiresAt.UTC()})
	return hash(key)
}

func activeGrant(cfg Config, req Request) (Grant, bool) {
	for _, g := range cfg.Grants {
		if g.Peer == req.Peer && g.Group == req.Group && g.Resource == req.Resource && g.Action == req.Action && g.ExpiresAt.After(time.Now()) && g.MaxUses >= 0 && g.BudgetTokens >= 0 {
			return g, true
		}
	}
	return Grant{}, false
}

func receiptDir(cfg Config) string { return filepath.Join(cfg.StateDir, "device-action-receipts") }

func receiptID(peer, request string) string { return hash([]byte(peer + "\x00" + request)) }

// HasRequestReceipt checks the original peer, resource and initiating action.
func HasRequestReceipt(cfg Config, peer, resource, request string) bool {
	r, err := load(filepath.Join(receiptDir(cfg), receiptID(peer, request)+".json"))
	if err != nil {
		return false
	}
	if r.Action != "" {
		return !IsFollowUp(r.Action) && r.Resource == resource
	}
	// Older receipts store the grant fingerprint without separate policy fields.
	for _, g := range cfg.Grants {
		if g.Peer == peer && g.Resource == resource && !IsFollowUp(g.Action) && g.ReceiptKey() == r.Grant {
			return true
		}
	}
	return false
}

// ResultTokens returns provider usage included in an action answer.
func ResultTokens(result json.RawMessage) int {
	var value struct{ Tokens int }
	if json.Unmarshal(result, &value) == nil && value.Tokens > 0 {
		return value.Tokens
	}
	return 0
}

func checkLimits(dir string, grant Grant) error {
	if IsFollowUp(grant.Action) || grant.MaxUses == 0 && grant.BudgetTokens == 0 {
		return nil
	}
	entries, err := os.ReadDir(dir)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	key := grant.ReceiptKey()
	uses, remaining := 0, grant.BudgetTokens
	for _, entry := range entries {
		if filepath.Ext(entry.Name()) != ".json" {
			continue
		}
		r, err := load(filepath.Join(dir, entry.Name()))
		if err != nil {
			return err
		}
		if r.Grant == key && !IsFollowUp(r.Action) {
			uses++
			if grant.BudgetTokens > 0 {
				remaining -= ResultTokens(r.Result)
				if remaining <= 0 {
					return ErrBudgetExhausted
				}
			}
		}
	}
	if grant.MaxUses > 0 && uses >= grant.MaxUses {
		return ErrDenied
	}
	return nil
}

// CheckBudget lets the device refuse a spent budget before asking for approval.
// Execute rechecks the limits under the admission lock before reserving a use.
func CheckBudget(cfg Config, req Request) error {
	g, ok := activeGrant(cfg, req)
	if !ok || g.BudgetTokens == 0 || IsFollowUp(req.Action) {
		return nil
	}
	dir := receiptDir(cfg)
	if _, err := os.Stat(filepath.Join(dir, receiptID(req.Peer, req.ID)+".json")); err == nil {
		return nil // Execute checks the existing operation's digest on replay.
	}
	g.MaxUses = 0
	return checkLimits(dir, g)
}

func Execute(ctx context.Context, cfg Config, req Request) (json.RawMessage, error) {
	if !identifier.MatchString(req.ID) || !identifier.MatchString(req.Peer) || !identifier.MatchString(req.Resource) || len(req.Payload) > 128<<10 || len(req.Payload) == 0 || !json.Valid(req.Payload) {
		return nil, ErrInvalid
	}
	var resource Resource
	for _, r := range cfg.Resources {
		if r.ID == req.Resource {
			if resource.ID != "" {
				return nil, ErrInvalid
			}
			resource = r
		}
	}
	implementation, known := registry[req.Action]
	if !known || resource.ID == "" || implementation.kind != registeredKind(resource) {
		return nil, ErrDenied
	}
	grant, ok := activeGrant(cfg, req)
	if !ok {
		return nil, ErrDenied
	}
	dir := receiptDir(cfg)
	if e := privateDir(dir); e != nil {
		return nil, ErrUnavailable
	}
	identity := receiptID(req.Peer, req.ID)
	path := filepath.Join(dir, identity+".json")
	var canonical map[string]any
	decoder := json.NewDecoder(bytes.NewReader(req.Payload))
	decoder.UseNumber()
	if err := decoder.Decode(&canonical); err != nil || canonical == nil {
		return nil, ErrInvalid
	}
	req.Payload, _ = json.Marshal(canonical)
	// An owner may remove and later reuse a display ID. Old receipts belong
	// only to the original target. Display names and refreshed grants may change.
	raw, _ := json.Marshal([]any{req, resource.Kind, resource.Target, resource.Repository, resource.Branch, resource.Base, resource.Run, resource.Coordinator})
	r, fresh, e := reserve(dir, path, hash(raw), grant)
	if e != nil {
		if errors.Is(e, ErrConflict) || errors.Is(e, ErrDenied) || errors.Is(e, ErrBudgetExhausted) {
			return nil, e
		}
		return nil, ErrUnavailable
	}
	if !fresh {
		switch r.Status {
		case "completed":
			return r.Result, nil
		case "failed":
			for _, failure := range actionFailures {
				if r.Failure == failure.err.Error() {
					return nil, failure.err
				}
			}
			return nil, ErrUnavailable
		}
		if !implementation.recoverable {
			return nil, ErrUncertain
		}
		// Read-only handlers and worker receipt lookup can reconcile a started record.
	}
	timed, cancel := context.WithDeadline(ctx, grant.ExpiresAt)
	defer cancel()
	r.Result, e = implementation.run(timed, cfg, resource, req, identity, !fresh)
	if e != nil {
		if !fresh || errors.Is(e, ErrUncertain) || errors.Is(e, context.Canceled) || errors.Is(e, context.DeadlineExceeded) {
			return nil, ErrUncertain
		}
		r.Status = "failed"
		for _, failure := range actionFailures {
			if errors.Is(e, failure.err) {
				r.Failure = failure.err.Error()
				break
			}
		}
		r.Result = nil
	} else {
		r.Status = "completed"
	}
	if err := save(path, r); err != nil {
		return nil, ErrUncertain
	}
	return r.Result, e
}
