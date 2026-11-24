//go:build darwin || linux

package service

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"agentcommander/internal/acpprocessor"
)

// Capture only the current flush. Advancing the producer after its marker and
// cursor have reached the client makes delivery comparisons independent of timer
// precision, goroutine scheduling, and SSE notification coalescing.
type operationBenchWriter struct {
	header  http.Header
	frame   bytes.Buffer
	onFlush func([]byte)
}

func (w *operationBenchWriter) Header() http.Header              { return w.header }
func (w *operationBenchWriter) Write(p []byte) (int, error)      { return w.frame.Write(p) }
func (w *operationBenchWriter) WriteHeader(int)                  {}
func (w *operationBenchWriter) SetWriteDeadline(time.Time) error { return nil }
func (w *operationBenchWriter) Flush() {
	w.onFlush(w.frame.Bytes())
	w.frame.Reset()
}

func benchmarkProcessCPU(b *testing.B) time.Duration {
	b.Helper()
	var usage syscall.Rusage
	if err := syscall.Getrusage(syscall.RUSAGE_SELF, &usage); err != nil {
		b.Fatal(err)
	}
	return time.Duration(usage.Utime.Nano() + usage.Stime.Nano())
}

func BenchmarkAGUIWorkerObserve(b *testing.B) {
	for _, workload := range []struct{ retained, updates int }{{96, 32}, {128, 32}, {128, 260}} {
		for _, mode := range []string{"snapshot", "incremental"} {
			b.Run(fmt.Sprintf("%d_retained/%d_appends/%s", workload.retained, workload.updates, mode), func(b *testing.B) {
				benchmarkWorkerObserve(b, workload.retained, workload.updates, mode)
			})
		}
	}
}

func benchmarkWorkerObserve(b *testing.B, retained, updates int, mode string) {
	const workerID, operationID = "w-bench", "op-bench"
	const path = "/v1/ag-ui/workers/" + workerID
	const runID = "bench"
	payload := strings.Repeat("x", 224)
	event := func(sequence int) ConsoleEvent {
		return ConsoleEvent{Kind: "text", Sequence: sequence, Text: fmt.Sprintf("text-%04d:%s", sequence, payload),
			ACP: &acpprocessor.Activity{Source: "live", Kind: "agent_message_chunk", ContentType: "text",
				Cursor: fmt.Sprintf("cursor-%04d", sequence), MessageID: "assistant-bench", TurnID: operationID}}
	}
	seed := make([]ConsoleEvent, retained)
	for i := range seed {
		seed[i] = event(i + 1)
	}
	accepts := make([]*http.Request, updates)
	markers, cursors := make([][]byte, updates+1), make([][]byte, updates+1)
	for i := 0; i <= updates; i++ {
		record := event(retained + i)
		markers[i] = []byte(record.Text)
		cursors[i] = []byte(record.ACP.Cursor)
		if i == 0 {
			continue
		}
		body, err := json.Marshal(workerOutput{Events: []ConsoleEvent{record}})
		if err != nil {
			b.Fatal(err)
		}
		r := httptest.NewRequest(http.MethodPost, path+"/output", nil)
		r.SetPathValue("worker", workerID)
		accepts[i-1] = r.WithContext(context.WithValue(r.Context(), bodyKey{}, body))
	}
	observe := httptest.NewRequest(http.MethodGet, path+"/operations/"+operationID+"?runId="+runID+"&projection="+mode, nil)
	observe.SetPathValue("worker", workerID)
	observe.SetPathValue("operation", operationID)
	finish := httptest.NewRequest(http.MethodPost, path+"/control/finish", nil)
	finish.SetPathValue("worker", workerID)
	finish = finish.WithContext(context.WithValue(finish.Context(), bodyKey{}, []byte(`{"state":"completed","message_id":"op-bench"}`)))
	worker := &Worker{ID: workerID, State: "working", NativeSession: &NativeSession{SessionID: "native-bench"},
		Control: &WorkerControl{Messages: []WorkerFollowUp{{ID: operationID, Status: "processing"}}}}
	run := &Run{ID: "r-bench", Status: "running", Workers: []*Worker{worker}}
	svc := &service{path: filepath.Join(b.TempDir(), "state.json"), consoleInstance: "bench", state: database{Runs: []*Run{run},
		Receipts: map[string]retryReceipt{receiptKey("", path+"/run", runID): {Target: operationID}}}}
	var initialBytes, appendBytes, terminalBytes int64
	var messageSnapshots int64
	b.ReportAllocs()
	b.ResetTimer()
	started := benchmarkProcessCPU(b)
	for range b.N {
		run.Status, worker.State = "running", "working"
		worker.Control.Messages[0] = WorkerFollowUp{ID: operationID, Status: "processing"}
		worker.Console = append(worker.Console[:0], seed...)
		ctx, cancel := context.WithTimeout(observe.Context(), 3*time.Second)
		next := 0
		var initial, lastAppend, wires int
		var sawText, sawCursor, finished bool
		var ingestErr error
		writer := &operationBenchWriter{header: make(http.Header)}
		writer.onFlush = func(frame []byte) {
			wires += len(frame)
			if next > updates {
				finished = finished || bytes.Contains(frame, []byte(`"type":"RUN_FINISHED"`))
				return
			}
			if next > 0 && bytes.Contains(frame, []byte(`"type":"MESSAGES_SNAPSHOT"`)) {
				messageSnapshots++
			}
			sawText = sawText || bytes.Contains(frame, markers[next])
			sawCursor = sawCursor || bytes.Contains(frame, cursors[next])
			if !sawText || !sawCursor {
				return
			}
			if next == 0 {
				initial = wires
			}
			svc.mu.Lock()
			if next == updates {
				lastAppend = wires
				_, ingestErr = svc.finishWorkerTurn(finish, workerID)
				svc.notifyOperations(workerID)
			} else {
				_, ingestErr = svc.output(accepts[next], workerID)
			}
			svc.mu.Unlock()
			next++
			sawText, sawCursor = false, false
			if ingestErr != nil {
				cancel()
			}
		}
		svc.observeWorkerRun(writer, observe.WithContext(ctx))
		cancel()
		if ingestErr != nil || next != updates+1 || !finished {
			b.Fatalf("observed %d of %d appended markers and cursors, finished=%t: %v", next-1, updates, finished, ingestErr)
		}
		initialBytes += int64(initial)
		appendBytes += int64(lastAppend - initial)
		terminalBytes += int64(wires - lastAppend)
	}
	cpu := benchmarkProcessCPU(b) - started
	b.StopTimer()
	b.ReportMetric(float64(cpu.Microseconds())/float64(b.N), "cpu-us/observe")
	b.ReportMetric(float64(initialBytes)/float64(b.N), "startup-wire-B/observe")
	b.ReportMetric(float64(terminalBytes)/float64(b.N), "finish-wire-B/observe")
	b.ReportMetric(float64(appendBytes)/float64(b.N*updates), "wire-B/append")
	b.ReportMetric(float64(messageSnapshots)/float64(b.N), "active-snapshots/observe")
	b.ReportMetric(float64(updates), "delivered/observe")
}
