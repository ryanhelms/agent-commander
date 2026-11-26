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
)

type Resource struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Kind        string `json:"kind"`
	Target      string `json:"target"`
	Branch      string `json:"branch,omitempty"`
	Repository  string `json:"repository,omitempty"`
	Base        string `json:"base,omitempty"`
	Run         string `json:"run,omitempty"`
	Coordinator bool   `json:"coordinator,omitempty"`
}
type Grant struct {
	ID        string    `json:"id,omitempty"`
	Peer      string    `json:"peer"`
	Resource  string    `json:"resource"`
	Action    string    `json:"action"`
	ExpiresAt time.Time `json:"expiresAt"`
	MaxUses   int       `json:"maxUses,omitempty"`
	// Approval is "ask" (each use waits for the owner) or "auto"/empty (runs within limits).
	Approval     string `json:"approval,omitempty"`
	BudgetTokens int    `json:"budgetTokens,omitempty"`
	Attribution  string `json:"attribution,omitempty"`
}
type Request struct {
	ID       string          `json:"id"`
	Peer     string          `json:"peer"`
	Resource string          `json:"resource"`
	Action   string          `json:"action"`
	Payload  json.RawMessage `json:"payload"`
}
type Config struct {
	StateDir, CommanderSocket string
	Resources                 []Resource
	Grants                    []Grant
	// GitHubToken selects a credential for this specific resource ID and capability.
	GitHubToken func(context.Context, string, string) (string, error)
	testGitHub  string
	testPushURL string
}

var (
	identifier       = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._:@-]{0,127}$`)
	ErrDenied        = errors.New("action is outside the current local grant")
	ErrInvalid       = errors.New("invalid action or target")
	ErrUncertain     = errors.New("outcome uncertain; reconcile the original operation")
	ErrConflict      = errors.New("operation identity or expected revision conflicts")
	ErrStaleRevision = fmt.Errorf("shared revision changed: %w", ErrConflict)
	ErrUnavailable   = errors.New("owner-local resource or credential unavailable")
)

var actionFailures = [...]struct {
	err  error
	code string
}{
	{ErrStaleRevision, "stale_revision"},
	{ErrConflict, "conflict"},
	{ErrDenied, "access_denied"},
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
	Digest  string          `json:"digest"`
	Grant   string          `json:"grant"`
	Status  string          `json:"status"`
	Result  json.RawMessage `json:"result,omitempty"`
	Failure string          `json:"failure,omitempty"`
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
func reserve(dir, path, digest, grant string, maxUses int) (receipt, bool, error) {
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
	if maxUses > 0 {
		entries, e := os.ReadDir(dir)
		if e != nil {
			return receipt{}, false, e
		}
		for _, entry := range entries {
			if filepath.Ext(entry.Name()) != ".json" {
				continue
			}
			stored, e := load(filepath.Join(dir, entry.Name()))
			if e != nil {
				return receipt{}, false, e
			}
			if stored.Grant == grant {
				maxUses--
				if maxUses == 0 {
					return receipt{}, false, ErrDenied
				}
			}
		}
	}
	r = receipt{Digest: digest, Grant: grant, Status: "started"}
	return r, true, save(path, r)
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
	var grant Grant
	for _, g := range cfg.Grants {
		if g.Peer == req.Peer && g.Resource == req.Resource && g.Action == req.Action && g.ExpiresAt.After(time.Now()) && g.MaxUses >= 0 {
			grant = g
			break
		}
	}
	if grant.Peer == "" {
		return nil, ErrDenied
	}
	dir := filepath.Join(cfg.StateDir, "device-action-receipts")
	if e := privateDir(dir); e != nil {
		return nil, ErrUnavailable
	}
	identity := hash([]byte(req.Peer + "\x00" + req.ID))
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
	key, _ := json.Marshal([]any{grant.ID, grant.Peer, grant.Resource, grant.Action, grant.ExpiresAt.UTC()})
	r, fresh, e := reserve(dir, path, hash(raw), hash(key), grant.MaxUses)
	if e != nil {
		if errors.Is(e, ErrConflict) || errors.Is(e, ErrDenied) {
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
