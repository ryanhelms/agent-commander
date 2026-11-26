package device

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"time"

	"agentcommander.network/pilot/internal/actions"
	"agentcommander.network/pilot/internal/control"
	"agentcommander.network/pilot/internal/identity"
)

func auditOutcome(status string, result json.RawMessage) string {
	switch status {
	case "completed", "expired", "denied":
		return status
	case "revoked":
		return "denied"
	case "pending", "processing":
		return "pending"
	case "declined":
		var failure struct{ Code string }
		_ = json.Unmarshal(result, &failure)
		switch failure.Code {
		case "denied", "access_denied":
			return "denied"
		case "expired", "budget_exhausted":
			return failure.Code
		}
	}
	return "failed"
}

// The frozen submission identifies each recipient even if a coordinator retries
// or the relay returns a fan-out in a different order.
func (r *sendRecord) updateAudit(c control.Child, value json.RawMessage) bool {
	idx := slices.IndexFunc(r.Audit, func(e AuditEntry) bool { return e.Request == c.ID })
	changed := false
	if idx < 0 {
		// Older submissions had a fixed 15-minute envelope and no audit entry.
		idx = len(r.Audit)
		r.Audit = append(r.Audit, AuditEntry{Request: c.ID, Peer: c.Owner, Resource: c.Resource, Action: c.Action, Started: c.ExpiresAt.Add(-15 * time.Minute)})
		changed = true
	}
	e := &r.Audit[idx]
	outcome, summary, tokens := auditOutcome(c.Status, value), summarize(value), actions.ResultTokens(value)
	if e.Outcome == outcome && e.Summary == summary && e.Tokens == tokens {
		return changed
	}
	e.Outcome, e.Summary, e.Tokens = outcome, summary, tokens
	if outcome == "pending" {
		e.Ended = time.Time{}
	} else {
		e.Ended = time.Now().UTC()
	}
	return true
}

func (a *Agent) audit(ctx context.Context, s identity.Session, resource, peer string) (any, error) {
	all := []AuditEntry{}
	include := func(e AuditEntry) bool {
		return (resource == "" || e.Resource == resource) && (peer == "" || e.Peer == peer)
	}
	err := a.walkOwnerAudit(func(e AuditEntry) bool {
		if (e.Recipient == "" || e.Recipient == s.User) && include(e) {
			if e.Outcome == "declined" || e.Outcome == "uncertain" {
				e.Outcome = auditOutcome(e.Outcome, json.RawMessage(e.Summary))
			}
			all = append(all, e)
		}
		return true
	})
	if err != nil {
		return nil, err
	}
	a.sendMu.Lock()
	defer a.sendMu.Unlock()
	err = a.walkSubmissions(s.User, func(path string, r *sendRecord) {
		// Tray sends can return before the owner decides. Opening audit settles
		// outstanding entries even when the sender never explicitly polls a receipt.
		if len(r.Audit) == 0 || slices.ContainsFunc(r.Audit, func(e AuditEntry) bool { return e.Outcome == "pending" && include(e) }) {
			// Offline devices can still display the last locally recorded outcome.
			_, _ = a.refreshSubmission(ctx, s, path, r)
		}
		for _, e := range r.Audit {
			if include(e) {
				all = append(all, e)
			}
		}
	})
	if err != nil {
		return nil, err
	}
	slices.SortStableFunc(all, func(x, y AuditEntry) int {
		return auditTime(y).Compare(auditTime(x))
	})
	if len(all) > 200 {
		all = all[:200]
	}
	return map[string]any{"entries": all}, nil
}

func auditTime(e AuditEntry) time.Time {
	if e.Ended.IsZero() {
		return e.Started
	}
	return e.Ended
}

func (r *sendRecord) pendingAudit() bool {
	return slices.ContainsFunc(r.Audit, func(e AuditEntry) bool { return e.Outcome == "pending" })
}

func (a *Agent) walkSubmissions(user string, visit func(string, *sendRecord)) error {
	dir := filepath.Join(a.cfg.Dir, key(user), "submissions")
	files, err := os.ReadDir(dir)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	for _, f := range files {
		if filepath.Ext(f.Name()) != ".json" {
			continue
		}
		path := filepath.Join(dir, f.Name())
		b, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		var r sendRecord
		if err := json.Unmarshal(b, &r); err != nil {
			return err
		}
		visit(path, &r)
	}
	return nil
}

// Settle requests whose caller closed the tray or never polled a receipt.
// Recover the outstanding IDs from disk once on startup or account change.
func (a *Agent) pollReceipts(ctx context.Context) {
	s, err := a.getSession(ctx)
	if err != nil {
		return
	}
	a.sendMu.Lock()
	if a.auditUser != s.User {
		pending := map[string]bool{}
		err = a.walkSubmissions(s.User, func(_ string, r *sendRecord) {
			if r.pendingAudit() {
				pending[r.Wire.ID] = true
			}
		})
		if err != nil {
			a.sendMu.Unlock()
			return
		}
		a.unsettled, a.auditUser = pending, s.User
	}
	ids := make([]string, 0, len(a.unsettled))
	for id := range a.unsettled {
		ids = append(ids, id)
	}
	a.sendMu.Unlock()
	for _, id := range ids {
		if ctx.Err() != nil {
			return
		}
		_, _ = a.receipt(ctx, s, id)
	}
}
