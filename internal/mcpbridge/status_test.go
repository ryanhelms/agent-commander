package mcpbridge

import (
	"bytes"
	"testing"
)

func TestStatusOmitsTerminalChurnAndKeepsCoordination(t *testing.T) {
	run := []byte(`{"id":"run","coordinator_id":"parent","workers":[{"id":"child","name":"Review","parent_id":"parent","state":"completed","result":"Reviewed","output":"TOKEN-LIKE-CONSOLE-TEXT"}],"requests":[{"id":"q","worker_id":"child","question":"Which version?","status":"answered","answer":"v2"}]}`)
	got, err := projectStatus(run)
	if err != nil {
		t.Fatal(err)
	}
	for _, field := range []string{`"parent_id":"parent"`, `"state":"completed"`, `"result":"Reviewed"`, `"question":"Which version?"`, `"answer":"v2"`} {
		if !bytes.Contains(got, []byte(field)) {
			t.Fatalf("missing %s in %s", field, got)
		}
	}
	if bytes.Contains(got, []byte("output")) || bytes.Contains(got, []byte("TOKEN-LIKE-CONSOLE-TEXT")) {
		t.Fatal("MCP status disclosed console output")
	}
	changedOutput := bytes.ReplaceAll(run, []byte("TOKEN-LIKE-CONSOLE-TEXT"), []byte("different output"))
	again, err := projectStatus(changedOutput)
	if err != nil || !bytes.Equal(again, got) {
		t.Fatal("console-only change should not wake status wait")
	}
	changedResult := bytes.ReplaceAll(run, []byte("Reviewed"), []byte("Found an issue"))
	again, err = projectStatus(changedResult)
	if err != nil || bytes.Equal(again, got) {
		t.Fatal("new worker findings should wake status wait")
	}
}
