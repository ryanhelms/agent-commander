package actions

import (
	"bufio"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Comment is one entry in a request's thread.
type Comment struct {
	ID         string    `json:"id"`
	Author     string    `json:"author"`
	AuthorKind string    `json:"authorKind"`
	At         time.Time `json:"at"`
	Text       string    `json:"text"`
}

func threadPath(cfg Config, request string) string {
	return filepath.Join(cfg.StateDir, "threads", hash([]byte(request))+".jsonl")
}

// AddComment appends a comment to a request's thread on this device.
func AddComment(cfg Config, request string, c Comment) (Comment, error) {
	if !identifier.MatchString(request) || strings.TrimSpace(c.Text) == "" || len(c.Text) > 4096 {
		return c, ErrInvalid
	}
	if c.AuthorKind != "agent" {
		c.AuthorKind = "person"
	}
	c.ID, c.At = hash([]byte(request + c.Author + time.Now().String()))[:16], time.Now().UTC()
	dir := filepath.Dir(threadPath(cfg, request))
	if e := privateDir(dir); e != nil {
		return c, ErrUnavailable
	}
	f, e := os.OpenFile(threadPath(cfg, request), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
	if e != nil {
		return c, ErrUnavailable
	}
	defer f.Close()
	b, _ := json.Marshal(c)
	if _, e = f.Write(append(b, '\n')); e != nil {
		return c, ErrUnavailable
	}
	return c, nil
}

// ReadThread returns a request's thread on this device, oldest first.
func ReadThread(cfg Config, request string) (map[string]any, error) {
	if !identifier.MatchString(request) {
		return nil, ErrInvalid
	}
	out := []Comment{}
	f, e := os.Open(threadPath(cfg, request))
	if e == nil {
		defer f.Close()
		sc := bufio.NewScanner(f)
		for sc.Scan() {
			var c Comment
			if json.Unmarshal(sc.Bytes(), &c) == nil {
				out = append(out, c)
			}
		}
	}
	return map[string]any{"request": request, "comments": out}, nil
}

func threadHandler(_ context.Context, cfg Config, _ Resource, req Request, _ string, _ bool) (json.RawMessage, error) {
	var in struct {
		Request string `json:"request"`
		Text    string `json:"text"`
	}
	if strict(req.Payload, &in) != nil || !identifier.MatchString(in.Request) {
		return nil, ErrInvalid
	}
	if !HasRequestReceipt(cfg, req.Peer, req.Resource, in.Request) &&
		(cfg.ReceivedRequest == nil || !cfg.ReceivedRequest(req.Peer, req.Resource, in.Request)) {
		return nil, ErrDenied
	}
	if req.Action == "thread.comment" {
		c, e := AddComment(cfg, in.Request, Comment{Author: req.Peer, AuthorKind: "person", Text: in.Text})
		if e != nil {
			return nil, e
		}
		return answer(c)
	}
	t, e := ReadThread(cfg, in.Request)
	if e != nil {
		return nil, e
	}
	return answer(t)
}
