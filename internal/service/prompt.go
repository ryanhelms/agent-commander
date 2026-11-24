package service

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"mime"
	"net/http"
	"strings"
)

type promptPartsKey struct{}

// PromptPart carries one ordered part in the private worker inbox.
type PromptPart struct {
	Type     string `json:"type"`
	Text     string `json:"text,omitempty"`
	MIMEType string `json:"mime_type,omitempty"`
	Data     []byte `json:"data,omitempty"`
}

type PromptCapabilities struct {
	Image bool `json:"image"`
	Audio bool `json:"audio"`
}

func (caps *PromptCapabilities) allows(parts []PromptPart) bool {
	for _, part := range parts {
		if part.Type == "image" && (caps == nil || !caps.Image) || part.Type == "audio" && (caps == nil || !caps.Audio) {
			return false
		}
	}
	return true
}

func aguiPrompt(raw json.RawMessage) (string, []PromptPart, error) {
	var text string
	if json.Unmarshal(raw, &text) == nil && len(raw) > 0 && raw[0] == '"' {
		return text, nil, nil
	}
	var parts []struct {
		Type   string
		Text   *string
		Source struct{ Type, MIMEType, Value string }
	}
	if err := json.Unmarshal(raw, &parts); err != nil || len(parts) == 0 {
		return "", nil, bad("expected text or an array of prompt parts")
	}
	var plain strings.Builder
	ordered := make([]PromptPart, 0, len(parts))
	for _, part := range parts {
		switch part.Type {
		case "text":
			if part.Text == nil {
				return "", nil, bad("a text prompt part requires a text string")
			}
			plain.WriteString(*part.Text)
			ordered = append(ordered, PromptPart{Type: "text", Text: *part.Text})
		case "image", "audio":
			if part.Source.Type != "data" {
				return "", nil, &apiError{http.StatusNotImplemented, "prompt media requires an inline data source"}
			}
			mimeType, parameters, err := mime.ParseMediaType(part.Source.MIMEType)
			data, decodeErr := base64.StdEncoding.Strict().DecodeString(part.Source.Value)
			if err != nil || len(parameters) != 0 || !strings.HasPrefix(mimeType, part.Type+"/") ||
				decodeErr != nil || len(data) == 0 {
				return "", nil, bad(fmt.Sprintf("%s prompt part requires base64 data and a matching MIME type", part.Type))
			}
			ordered = append(ordered, PromptPart{Type: part.Type, MIMEType: mimeType, Data: data})
		default:
			return "", nil, &apiError{http.StatusNotImplemented, "this prompt content type is unavailable"}
		}
	}
	if len(ordered) == 1 && ordered[0].Type == "text" {
		// The existing string path sends this same single ACP text block.
		return ordered[0].Text, nil, nil
	}
	return plain.String(), ordered, nil
}
