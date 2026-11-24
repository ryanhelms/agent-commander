package provider

import (
	"context"
	"strconv"
	"strings"
	"testing"
	"time"

	"agentcommander/internal/service"
)

func TestSourceQueuePlacesOverflowAtItsFirstCursor(t *testing.T) {
	q := newSourceQueue()
	session := service.NativeSession{HarnessInstance: "h", SessionID: "s"}
	q.bind(session)
	push := func(n int, turn string) bool {
		return q.put(nil, service.LiveSourceUpdate{Session: session, Cursor: strconv.Itoa(n), TurnID: turn})
	}
	for i := range sourceQueueRecords {
		if !push(i, "first") {
			t.Fatal("early loss", i)
		}
	}
	if push(128, "first") || push(129, "second") {
		t.Fatal("unbounded queue")
	}
	received := q.get(nil)
	if !push(130, "second") {
		t.Fatal("recovered queue refused update")
	}
	q.close()
	for {
		page := q.get(nil)
		if len(page) == 0 {
			break
		}
		received = append(received, page...)
	}
	if len(received) != 130 {
		t.Fatal(len(received))
	}
	for i := range 128 {
		if received[i].Cursor != strconv.Itoa(i) || received[i].Gap != "" {
			t.Fatal(i, received[i])
		}
	}
	gap := received[128]
	if gap.Cursor != "128" || gap.TurnID != "" || gap.Session != session || !strings.Contains(gap.Gap, "2 ACP source records") || received[129].Cursor != "130" {
		t.Fatal("loss did not retain its position and session", gap)
	}
}

func TestSourceQueueBytePressureAndShutdown(t *testing.T) {
	q := newSourceQueue()
	session := service.NativeSession{HarnessInstance: "h", SessionID: "s"}
	q.bind(session)
	record := service.LiveSourceUpdate{Session: session, TurnID: "turn", Body: make([]byte, service.MaxLiveSourceRecord)}
	for i := range 5 {
		record.Cursor = strconv.Itoa(i)
		if !q.put(nil, record) {
			t.Fatal("early loss", i)
		}
	}
	record.Cursor = "lost"
	if q.put(nil, record) {
		t.Fatal("exceeded byte budget")
	}
	// The prompt producer can wait for the callback-safe ring to drain.
	published := make(chan bool, 1)
	record.Cursor = "prompt"
	go func() { published <- q.put(t.Context(), record) }()
	if len(q.get(nil)) != 1 {
		t.Fatal("batch wire budget exceeded")
	}
	select {
	case admitted := <-published:
		if !admitted {
			t.Fatal("prompt refused after capacity was released")
		}
	case <-time.After(time.Second):
		t.Fatal("producer stuck after draining")
	}
	record.Cursor = "cancelled"
	cancelled, cancel := context.WithCancel(t.Context())
	cancel()
	if q.put(cancelled, record) {
		t.Fatal("cancelled producer admitted to full queue")
	}
	record.Cursor = "closed"
	go func() { published <- q.put(t.Context(), record) }()
	q.close()
	select {
	case admitted := <-published:
		if admitted {
			t.Fatal("closed producer accepted")
		}
	case <-time.After(time.Second):
		t.Fatal("producer stuck on closed queue")
	}
	var got []service.LiveSourceUpdate
	for {
		page := q.get(nil)
		if len(page) == 0 {
			break
		}
		got = append(got, page...)
	}
	if len(got) != 7 || got[4].Cursor != "lost" || got[4].Gap == "" || got[5].Cursor != "prompt" ||
		got[6].Cursor != "cancelled" || got[6].Gap == "" || got[6].TurnID != "turn" {
		t.Fatalf("unexpected gap or record order (count %d)", len(got))
	}
}

func TestSourceQueueBindsPreOpenCallbacks(t *testing.T) {
	q := newSourceQueue()
	selected := service.NativeSession{SessionID: "one", HarnessInstance: "adapter"}
	other := service.NativeSession{SessionID: "two", HarnessInstance: "adapter"}
	q.put(nil, service.LiveSourceUpdate{Session: other, Cursor: "foreign"})
	q.put(nil, service.LiveSourceUpdate{Session: selected, Cursor: "wanted"})
	q.bind(selected)
	if q.put(nil, service.LiveSourceUpdate{Session: other, Cursor: "later-foreign"}) {
		t.Fatal("foreign update accepted")
	}
	q.close()
	data := q.get(nil)
	if len(data) != 1 || data[0].Cursor != "wanted" || len(q.get(nil)) != 0 {
		t.Fatal("pre-open scope leaked")
	}
}
