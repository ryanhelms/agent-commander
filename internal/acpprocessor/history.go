package acpprocessor

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"

	model "agent-acp.local/sdks/go/model"
	"agent-acp.local/sdks/go/runtime"
	"google.golang.org/protobuf/encoding/protojson"
)

// HistoryView renders an already authorized SDK history page. Each source
// record occupies one output position, preserving the input cursor contract.
// Only the ACP variant payload changes encoding, from Protobuf JSON's bytes
// field to the original ACP object. Portable/native records keep their schema.
func HistoryView(page json.RawMessage) (json.RawMessage, error) {
	var input struct {
		Observations []json.RawMessage `json:"observations"`
		NextCursor   string            `json:"nextCursor"`
	}
	if err := json.Unmarshal(page, &input); err != nil {
		return nil, err
	}
	type record struct {
		Session        json.RawMessage `json:"session,omitempty"`
		Cursor         string          `json:"cursor,omitempty"`
		TurnID         string          `json:"turnId,omitempty"`
		Disposition    string          `json:"disposition"`
		Update         json.RawMessage `json:"update,omitempty"`
		ParamsFields   json.RawMessage `json:"paramsFields,omitempty"`
		WireProvenance json.RawMessage `json:"wireProvenance,omitempty"`
		Observation    json.RawMessage `json:"observation,omitempty"`
	}
	out := struct {
		Records    []record `json:"records"`
		NextCursor string   `json:"nextCursor"`
	}{make([]record, 0, len(input.Observations)), input.NextCursor}
	for _, original := range input.Observations {
		var item struct {
			Session        json.RawMessage `json:"session"`
			Cursor         string          `json:"cursor"`
			TurnID         string          `json:"turnId"`
			Extension      json.RawMessage `json:"extension"`
			SourceRecord   json.RawMessage `json:"sourceRecord"`
			WireProvenance json.RawMessage `json:"wireProvenance"`
		}
		if err := json.Unmarshal(original, &item); err != nil {
			return nil, err
		}
		r := record{Session: item.Session, Cursor: item.Cursor, TurnID: item.TurnID,
			Disposition: "portable", Observation: original}
		source := item.SourceRecord
		if len(source) == 0 {
			source = item.Extension
		}
		var extType struct{ Type string }
		if len(source) > 0 && json.Unmarshal(source, &extType) == nil && extType.Type == runtime.ACPUpdateParamsSource {
			var ext model.Extension
			var ref model.SessionRef
			if err := protojson.Unmarshal(source, &ext); err != nil {
				return nil, err
			}
			if err := protojson.Unmarshal(item.Session, &ref); err != nil {
				return nil, err
			}
			inner, fields, err := splitUpdateParams(ext.Data, ref.SessionId, true)
			if err != nil {
				return nil, err
			}
			r.Disposition, r.Update, r.ParamsFields, r.Observation = Decode(inner).Disposition, inner, fields, nil
		} else if len(item.Extension) > 0 {
			var ext model.Extension
			if err := protojson.Unmarshal(item.Extension, &ext); err != nil {
				return nil, err
			}
			var reported struct{ Gap json.RawMessage }
			if ext.Type == "agentacp.observation" && ext.MediaType == "application/json" && json.Unmarshal(ext.Data, &reported) == nil && len(reported.Gap) > 0 {
				var gap model.Observation
				var session model.SessionRef
				if protojson.Unmarshal(ext.Data, &gap) != nil || protojson.Unmarshal(item.Session, &session) != nil || gap.GetGap() == nil ||
					gap.GetSession().GetSessionId() != session.SessionId || gap.GetSession().GetHarnessInstance() != session.HarnessInstance || gap.TurnId != item.TurnID {
					return nil, errors.New("gap observation does not match its selected session")
				}
				// Keep the synthetic source cursor on the record and the exact
				// provider reason, optional cursor and source fields in its original.
				r.Observation = ext.Data
			} else if u, ok := ExtensionUpdate(&ext); ok {
				r.Disposition = u.Disposition
				if json.Valid(u.Raw) {
					r.Update, r.Observation = u.Raw, nil
				}
			}
		}
		// Flattened ACP records still carry the transport envelope. Portable
		// records already contain it in their original observation.
		if len(r.Observation) == 0 {
			r.WireProvenance = item.WireProvenance
		}
		out.Records = append(out.Records, r)
	}
	return json.Marshal(out)
}

// ExtensionUpdate recognizes SDK replay/live source wrappers and the direct
// discriminated extensions produced by the SDK's default session normalizer.
func ExtensionUpdate(ext *model.Extension) (Update, bool) {
	if ext == nil || ext.MediaType != "application/json" || len(ext.Data) == 0 {
		return Update{}, false
	}
	if ext.Type == runtime.ACPUpdateParamsSource {
		inner, _, _ := splitUpdateParams(ext.Data, "", false)
		return Decode(inner), true
	}
	u := Decode(ext.Data)
	return u, ext.Type == "acp.session_update" || ext.Type == "acp.replay_update" ||
		u.Kind != "" && u.Kind == ext.Type
}

// ScopedUpdate checks an original notification's outer binding and returns its
// exact inner value. A null value and an absent member remain distinguishable.
func ScopedUpdate(raw []byte, expected string) (json.RawMessage, error) {
	if expected == "" {
		return nil, errors.New("missing bound ACP session")
	}
	inner, _, err := splitUpdateParams(raw, expected, false)
	return inner, err
}

func splitUpdateParams(raw []byte, expected string, retainSiblings bool) (json.RawMessage, json.RawMessage, error) {

	dec := json.NewDecoder(bytes.NewReader(raw))
	open, err := dec.Token()
	if err != nil || open != json.Delim('{') {
		return nil, nil, errors.New("invalid ACP update params")
	}
	var inner json.RawMessage
	var bound bool
	var siblings bytes.Buffer
	if retainSiblings {
		siblings.WriteByte('{')
	}
	for dec.More() {
		key, err := dec.Token()
		name, ok := key.(string)
		if err != nil || !ok {
			return nil, nil, errors.New("invalid ACP update field")
		}
		var v json.RawMessage
		if err := dec.Decode(&v); err != nil {
			return nil, nil, err
		}
		switch name {
		case "sessionId":
			var id string
			if bound || json.Unmarshal(v, &id) != nil || id == "" || (expected != "" && id != expected) {
				return nil, nil, errors.New("ACP update does not match bound session")
			}
			bound = true
		case "update":
			if inner != nil {
				return nil, nil, errors.New("ambiguous ACP update")
			}
			inner = v
			continue
		}
		if retainSiblings {
			if siblings.Len() > 1 {
				siblings.WriteByte(',')
			}
			keyJSON, _ := json.Marshal(name)
			siblings.Write(keyJSON)
			siblings.WriteByte(':')
			siblings.Write(v)
		}
	}
	if !bound {
		return nil, nil, errors.New("missing ACP update session")
	}
	if _, err := dec.Token(); err != nil {
		return nil, nil, err
	}
	if _, err := dec.Token(); err != io.EOF {
		return nil, nil, errors.New("unexpected data after ACP update")
	}
	if retainSiblings {
		siblings.WriteByte('}')
	}
	return inner, siblings.Bytes(), nil
}
