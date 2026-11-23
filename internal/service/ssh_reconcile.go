package service

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"time"
)

type sshReplyEvidence struct {
	RequestID string `json:"request_id"`
	Delivery  string `json:"delivery"`
	Source    string `json:"source"`
}

func (s *service) reconcileSSHReply(w http.ResponseWriter, req *http.Request) {
	id := req.PathValue("qid")
	s.mu.Lock()
	q, ref, cwd, err := s.sshReconciliationTarget(req, id)
	s.mu.Unlock()
	if err != nil {
		respondError(w, err)
		return
	}

	reader, ok := s.launcher.(nativeHistoryPager)
	if !ok {
		respondError(w, &apiError{http.StatusNotImplemented, "native history paging is unavailable"})
		return
	}
	ctx, cancel := context.WithTimeout(req.Context(), 12*time.Second)
	defer cancel()
	confirmed, err := findSSHReply(ctx, reader, ref, cwd, q)
	if err != nil {
		respondError(w, &apiError{http.StatusServiceUnavailable, "native reply evidence is unavailable"})
		return
	}

	s.mu.Lock()
	current, currentRef, currentCWD, err := s.sshReconciliationTarget(req, id)
	evidence := sshReplyEvidence{RequestID: id, Delivery: current.Delivery, Source: "native_history"}
	if err == nil {
		if ref != currentRef || cwd != currentCWD || current.Answer != q.Answer {
			err = conflict("original SSH request changed during reconciliation")
		} else if confirmed && current.Delivery != "confirmed" {
			_, original := s.question(id)
			original.Delivery = "confirmed"
			err = s.persist()
			if err != nil {
				original.Delivery = current.Delivery
			} else {
				evidence.Delivery = original.Delivery
			}
		}
	}
	s.mu.Unlock()
	if err != nil {
		respondError(w, err)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(evidence)
}

// sshReconciliationTarget runs with the service lock held. The native session
// reference and answer are immutable inputs to the remote read.
func (s *service) sshReconciliationTarget(req *http.Request, id string) (Question, NativeSession, string, error) {
	actor := ""
	if _, supplied := req.Header["Authorization"]; supplied {
		bearer, ok := strings.CutPrefix(req.Header.Get("Authorization"), "Bearer ")
		actor = s.state.Tokens[digest(bearer)]
		if !ok || bearer == "" || actor == "" {
			return Question{}, NativeSession{}, "", denied()
		}
	}
	run, q := s.question(id)
	if q == nil {
		return Question{}, NativeSession{}, "", missing("question")
	}
	_, worker := s.worker(q.WorkerID)
	if actor != "" && (actor == q.WorkerID || (actor != worker.ParentID && actor != run.CoordinatorID)) {
		return Question{}, NativeSession{}, "", denied()
	}
	if worker.NativeSession == nil || worker.Host == "" || worker.Host == "localhost" ||
		q.Status != "answered" || (q.Delivery != "unknown" && q.Delivery != "confirmed") {
		return Question{}, NativeSession{}, "", conflict("request has no ambiguous SSH reply to reconcile")
	}
	return *q, *worker.NativeSession, worker.Worktree, nil
}

func findSSHReply(ctx context.Context, reader nativeHistoryPager, ref NativeSession, cwd string, q Question) (bool, error) {
	waitCalls := map[string]bool{}
	cursor := ""
	// A bounded read can leave the answer unresolved. Absence of evidence never
	// grants permission to replay an operation.
	for range 32 {
		raw, err := reader.ReadNativeHistoryPage(ctx, ref, cwd, cursor, 128)
		if err != nil {
			return false, err
		}
		var page struct {
			NextCursor   string `json:"nextCursor"`
			Observations []struct {
				Tool *struct {
					CallID, Name, Phase, Summary string
				}
			}
		}
		if err := json.Unmarshal(raw, &page); err != nil {
			return false, err
		}
		for _, obs := range page.Observations {
			tool := obs.Tool
			if tool == nil || tool.CallID == "" {
				continue
			}
			switch tool.Phase {
			case "started":
				if tool.Name != "mcp__commander__commander_wait" {
					continue
				}
				var input struct {
					RequestID string `json:"request_id"`
				}
				if json.Unmarshal([]byte(tool.Summary), &input) == nil && input.RequestID == q.ID {
					waitCalls[tool.CallID] = true
				}
			case "completed":
				if waitCalls[tool.CallID] && containsSSHReply(tool.Summary, q) {
					return true, nil
				}
			}
		}
		if page.NextCursor == "" || page.NextCursor == cursor {
			break
		}
		cursor = page.NextCursor
	}
	return false, nil
}

func containsSSHReply(summary string, q Question) bool {
	var content []struct{ Type, Text string }
	if json.Unmarshal([]byte(summary), &content) != nil {
		return false
	}
	for _, cell := range content {
		var observed Question
		if cell.Type == "text" && json.Unmarshal([]byte(cell.Text), &observed) == nil &&
			observed.ID == q.ID && observed.WorkerID == q.WorkerID && observed.Status == "answered" && observed.Answer == q.Answer {
			return true
		}
	}
	return false
}
