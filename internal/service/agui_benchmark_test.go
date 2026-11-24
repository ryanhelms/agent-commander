package service

import (
	"fmt"
	"slices"
	"strings"
	"testing"
)

// Measure the projection and encoding one workspace subscriber performs after a
// change. Only the first worker changes. Each run has up to ten workers.
func BenchmarkAGUIWorkspaceUpdate(b *testing.B) {
	for _, workers := range []int{1, 30} {
		for _, records := range []int{4, 128} {
			b.Run(fmt.Sprintf("%d_workers/%d_text_records_each", workers, records), func(b *testing.B) {
				var svc service
				payload := strings.Repeat("x", 255) + "\n"
				for i := 0; i < workers; i++ {
					if i%10 == 0 {
						svc.state.Runs = append(svc.state.Runs, &Run{ID: fmt.Sprintf("r%d", i/10)})
					}
					run := svc.state.Runs[i/10]
					w := &Worker{ID: fmt.Sprintf("w%d", i), Output: strings.Repeat(payload, records)}
					for seq := 1; seq <= records; seq++ {
						w.Console = append(w.Console, ConsoleEvent{Sequence: seq, Kind: "text", Text: payload})
					}
					run.Workers = append(run.Workers, w)
				}
				feed := workspaceProjection{incrementalReaders: 1}
				feed.rebuild(svc.state.Runs)
				first := svc.state.Runs[0].Workers[0]
				originals := first.Console
				edited := slices.Clone(originals)
				edited[records-1].Text = "y" + payload[1:]
				originalOutput := first.Output
				editedOutput := originalOutput[:len(originalOutput)-len(payload)] + edited[records-1].Text

				var size int
				b.ReportAllocs()
				for b.Loop() {
					if first.Output == originalOutput {
						first.Console, first.Output = edited, editedOutput
					} else {
						first.Console, first.Output = originals, originalOutput
					}
					cursor := feed.revision
					feed.rebuild(svc.state.Runs)
					if feed.revision == cursor {
						b.Fatal("projection missed a changed record")
					}
					data, _, err := feed.next(cursor, true)
					if err != nil {
						b.Fatal(err)
					}
					size = len(data) - len("data: ") - len("\n\n")
				}
				b.ReportMetric(float64(size), "wire-B/update")
			})
		}
	}
}
