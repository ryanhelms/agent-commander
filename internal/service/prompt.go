package service

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"mime"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"unicode"

	"agentcommander/internal/hosted"
)

type promptPartsKey struct{}

// PromptPart carries one ordered part in the private worker inbox.
type PromptPart struct {
	Type         string  `json:"type"`
	Text         string  `json:"text,omitempty"`
	MIMEType     string  `json:"mime_type,omitempty"`
	Data         []byte  `json:"data,omitempty"`
	URI          string  `json:"uri,omitempty"`
	Name         string  `json:"name,omitempty"`
	ResourceText *string `json:"resource_text,omitempty"`
}

type PromptCapabilities struct {
	Image           bool `json:"image"`
	Audio           bool `json:"audio"`
	ResourceLink    bool `json:"resourceLink,omitempty"`
	EmbeddedContext bool `json:"embeddedContext,omitempty"`
}

func (caps *PromptCapabilities) allows(parts []PromptPart) bool {
	for _, part := range parts {
		switch part.Type {
		case "image":
			if caps == nil || !caps.Image {
				return false
			}
		case "audio":
			if caps == nil || !caps.Audio {
				return false
			}
		case "resource_link":
			if caps == nil || !caps.ResourceLink {
				return false
			}
		case "resource":
			if caps == nil || !caps.EmbeddedContext {
				return false
			}
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
		Type                string
		Text                *string
		URI, Name, MIMEType string
		Source              struct{ Type, MIMEType, Value string }
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
		case "resource_link", "resource":
			address, err := url.Parse(part.URI)
			if err != nil || !address.IsAbs() || len(part.URI) > 4096 || len(part.Name) > 256 ||
				strings.IndexFunc(part.URI+part.Name, unicode.IsControl) >= 0 {
				return "", nil, bad("invalid prompt resource URI or name")
			}
			resource := PromptPart{Type: part.Type, URI: part.URI, Name: part.Name, MIMEType: part.MIMEType}
			if resource.MIMEType != "" {
				if _, _, err := mime.ParseMediaType(resource.MIMEType); err != nil {
					return "", nil, bad("invalid prompt resource MIME type")
				}
			}
			if part.Type == "resource_link" {
				if strings.TrimSpace(part.Name) == "" || address.Scheme != "file" || address.Host != "" ||
					address.Opaque != "" || address.RawQuery != "" || address.Fragment != "" || !filepath.IsAbs(address.Path) {
					return "", nil, bad("a local file reference requires a name and an absolute file URI")
				}
			} else {
				switch part.Source.Type {
				case "text":
					resource.ResourceText = &part.Source.Value
				case "data":
					data, err := base64.StdEncoding.Strict().DecodeString(part.Source.Value)
					if err != nil {
						return "", nil, bad("an embedded blob requires valid base64")
					}
					resource.Data = data
				default:
					return "", nil, bad("an embedded resource requires inline text or base64 data")
				}
			}
			ordered = append(ordered, resource)
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

func validatePromptResourceLinks(directory string, parts []PromptPart) error {
	root, err := filepath.EvalSymlinks(directory)
	if err != nil {
		return bad("the selected worker has no accessible resource directory")
	}
	for _, part := range parts {
		if part.Type != "resource_link" {
			continue
		}
		address, _ := url.Parse(part.URI) // already validated by aguiPrompt
		canonical, err := filepath.EvalSymlinks(address.Path)
		if err != nil || canonical != address.Path {
			return bad("file references must use the current canonical path")
		}
		relative, err := filepath.Rel(root, canonical)
		if err != nil || relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
			return bad("file references must belong to the selected worker checkout")
		}
		if stat, err := os.Stat(canonical); err != nil || !stat.Mode().IsRegular() {
			return bad("a file reference requires a regular file")
		}
	}
	return nil
}

func (s *service) prepareWorkerPrompt(request *http.Request, raw []byte) (*http.Request, error) {
	var input struct {
		Text       string
		Generation int
		Content    json.RawMessage
	}
	if json.Unmarshal(raw, &input) != nil || len(input.Content) == 0 {
		return request, nil // preserve the normal text command decoder and API errors
	}
	if input.Text != "" {
		return nil, bad("send either text or ordered prompt content")
	}
	text, parts, err := aguiPrompt(input.Content)
	if err != nil {
		return nil, err
	}
	if _, present := request.Header["Authorization"]; present {
		return nil, denied()
	}
	if err := s.checkPromptResourceScope(request, parts); err != nil {
		return nil, err
	}
	body, _ := json.Marshal(struct {
		Text       string
		Generation int
	}{text, input.Generation})
	ctx := context.WithValue(request.Context(), bodyKey{}, body)
	return request.WithContext(context.WithValue(ctx, promptPartsKey{}, parts)), nil
}

func (s *service) checkPromptResourceScope(request *http.Request, parts []PromptPart) error {
	if !slices.ContainsFunc(parts, func(part PromptPart) bool { return part.Type == "resource_link" }) {
		return nil
	}
	if hosted.From(request.Context()) != nil {
		return denied()
	}
	s.mu.Lock()
	_, worker := s.worker(request.PathValue("worker"))
	var directory string
	if worker != nil && (worker.Host == "" || worker.Host == "localhost") {
		directory = worker.Worktree
	}
	s.mu.Unlock()
	if directory == "" {
		return denied()
	}
	return validatePromptResourceLinks(directory, parts)
}
