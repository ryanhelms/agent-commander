package acpprocessor

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"testing"
)

func TestScopedParamsKeepsRepeatedFutureFieldsAndRequiresExactRouting(t *testing.T) {
	raw := []byte(`{"sessionId":"selected","unknown":1,"update":{"sessionUpdate":"plan","entries":[]},"unknown":2}`)
	inner, fields, err := splitUpdateParams(raw, "selected", true)
	if err != nil || Decode(inner).Kind != "plan" || bytes.Count(fields, []byte(`"unknown"`)) != 2 {
		t.Fatal("lost original unknown members", err)
	}
	for _, raw := range []string{`{"sessionId":"different","update":null}`, `{"sessionId":"selected","sessionId":"different","update":null}`, `{"SESSIONID":"selected","update":null}`, `{"sessionId":"selected","update":null,"update":{}}`, `{"sessionId":"selected"}[]`} {
		if _, err := ScopedUpdate([]byte(raw), "selected"); err == nil {
			t.Fatal("accepted ambiguous/unbound notification", raw)
		}
	}
}

func TestHistoryViewKeepsWireProvenanceBesideOriginalPayload(t *testing.T) {
	wire := `{"kind":"WIRE_MESSAGE_KIND_NOTIFICATION","protocolVersion":"2.0","method":"session/update","additionalFieldsJson":"{\"vendor\":9007199254740993}"}`
	params := `{"sessionId":"s","vendor":null,"update":{"sessionUpdate":"tool_call_update","toolCallId":"t","rawOutput":"unique-attachment"}}`
	page := fmt.Sprintf(`{"observations":[{"session":{"sessionId":"s"},"cursor":"a","sourceRecord":{"type":"acp.session_update_params","mediaType":"application/json","data":%q},"wireProvenance":%s},{"cursor":"b","turnEnded":{"reason":"end_turn"},"wireProvenance":{"kind":"WIRE_MESSAGE_KIND_RESULT","idJson":"2e+0"}}]}`, base64.StdEncoding.EncodeToString([]byte(params)), wire)
	output, err := HistoryView([]byte(page))
	if err != nil {
		t.Fatal(err)
	}
	var result struct {
		Records []struct {
			WireProvenance, ParamsFields, Observation json.RawMessage
		}
	}
	if err := json.Unmarshal(output, &result); err != nil || len(result.Records) != 2 {
		t.Fatalf("unexpected history page: %s (%v)", output, err)
	}
	first, second := result.Records[0], result.Records[1]
	if string(first.WireProvenance) != wire || !bytes.Contains(first.ParamsFields, []byte(`"vendor":null`)) ||
		bytes.Count(output, []byte("unique-attachment")) != 1 || bytes.Count(output, []byte("wireProvenance")) != 2 ||
		len(second.WireProvenance) != 0 || !bytes.Contains(second.Observation, []byte(`"idJson":"2e+0"`)) {
		t.Fatalf("changed payload or transport fields: %s", output)
	}
}
