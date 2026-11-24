package provider

import (
	"context"
	"fmt"
	"sync"

	"agentcommander/internal/service"
)

const sourceQueueRecords = 128

// ACP invokes source callbacks while holding the session lock. Keep recent
// records in order without making a callback wait on HTTP. Only the runner's
// own prompt and observation producers may wait for space.
type sourceQueue struct {
	mu        sync.Mutex
	available *sync.Cond
	space     chan struct{}
	closed    bool
	session   service.NativeSession
	records   [sourceQueueRecords]sourceSlot
	head      int
	count     int
	bytes     int
	missed    *sourceLoss
}

type sourceSlot struct {
	update service.LiveSourceUpdate
	before *sourceLoss
}

type sourceLoss struct {
	session     service.NativeSession
	turn, first string
	count       int
}

func (loss *sourceLoss) add(update service.LiveSourceUpdate) *sourceLoss {
	if loss == nil {
		loss = &sourceLoss{session: update.Session, turn: update.TurnID, first: update.Cursor}
	}
	if loss.turn != update.TurnID {
		loss.turn = ""
	}
	loss.count++
	return loss
}

func (loss *sourceLoss) record(reason string) service.LiveSourceUpdate {
	noun := "record"
	if loss.count != 1 {
		noun = "records"
	}
	return service.LiveSourceUpdate{Session: loss.session, TurnID: loss.turn, Cursor: loss.first,
		Gap: fmt.Sprintf("%d ACP source %s %s", loss.count, noun, reason)}
}

func newSourceQueue() *sourceQueue {
	q := &sourceQueue{}
	q.available = sync.NewCond(&q.mu)
	return q
}

func (q *sourceQueue) bind(session service.NativeSession) {
	q.mu.Lock()
	defer q.mu.Unlock()
	// Callbacks may already have arrived during Open. Compact the pre-bind
	// records before a screen or source reader can observe a foreign session.
	n := 0
	for i := 0; i < q.count; i++ {
		slot := q.records[i]
		if slot.update.Session != session {
			continue
		}
		q.records[n] = slot
		n++
	}
	clear(q.records[n:q.count])
	q.count, q.bytes = n, 0
	for i := range n {
		q.bytes += q.records[i].update.RetainedSize()
	}
	if q.missed != nil && q.missed.session != session {
		q.missed = nil
	}
	q.session = session
}

func (q *sourceQueue) put(ctx context.Context, update service.LiveSourceUpdate) bool {
	size := update.RetainedSize()
	q.mu.Lock()
	defer q.mu.Unlock()
	for {
		if q.closed || q.session.SessionID != "" && q.session != update.Session {
			return false
		}
		if q.count < len(q.records) && q.bytes+size <= service.LiveSourceWindowBytes {
			at := (q.head + q.count) % len(q.records)
			q.records[at] = sourceSlot{update: update, before: q.missed}
			q.missed = nil
			q.count++
			q.bytes += size
			q.available.Signal()
			return true
		}
		if size > service.LiveSourceWindowBytes || ctx == nil || ctx.Err() != nil {
			if q.missed == nil || q.missed.session == update.Session {
				q.missed = q.missed.add(update)
				q.available.Signal()
			}
			return false
		}
		if q.space == nil {
			q.space = make(chan struct{})
		}
		space := q.space
		q.mu.Unlock()
		select {
		case <-space:
		case <-ctx.Done():
		}
		q.mu.Lock()
	}
}

// get waits only for the first record. It amortizes socket writes across the
// records already waiting, with enough room for the JSON/base64 HTTP envelope.
func (q *sourceQueue) get(batch []service.LiveSourceUpdate) []service.LiveSourceUpdate {
	q.mu.Lock()
	defer q.mu.Unlock()
	for q.count == 0 && q.missed == nil && !q.closed {
		q.available.Wait()
	}
	const maxBatchBytes = 1 << 20
	bytes := 0
	for q.count > 0 && len(batch) < service.LiveSourceBatchRecords {
		slot := &q.records[q.head]
		if slot.before != nil {
			gap := slot.before.record("could not enter the bounded runner queue")
			batch = append(batch, gap)
			bytes += gap.RetainedSize()
			slot.before = nil
			continue
		}
		size := slot.update.RetainedSize()
		if len(batch) > 0 && bytes+size > maxBatchBytes {
			break
		}
		batch = append(batch, slot.update)
		bytes += size
		q.bytes -= size
		*slot = sourceSlot{}
		q.head = (q.head + 1) % len(q.records)
		q.count--
	}
	if q.count == 0 && q.missed != nil && len(batch) < service.LiveSourceBatchRecords {
		batch = append(batch, q.missed.record("could not enter the bounded runner queue"))
		q.missed = nil
	}
	if q.space != nil {
		close(q.space)
		q.space = nil
	}
	return batch
}

func (q *sourceQueue) close() {
	q.mu.Lock()
	defer q.mu.Unlock()
	q.closed = true
	q.available.Broadcast()
	if q.space != nil {
		close(q.space)
		q.space = nil
	}
}
