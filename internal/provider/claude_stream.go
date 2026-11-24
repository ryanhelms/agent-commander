package provider

import (
	"encoding/json"
	"strings"
	"unicode/utf8"
)

type claudePartialBlock struct {
	session, parent string
	index           int
	text            string
	truncated       bool
}

// The CLI can send partial blocks and complete assistant envelopes for the
// same message. Buffer text until the enclosing record arrives. Recover an
// unmatched block when the stream advances or ends.
type claudePartialText []claudePartialBlock

func (p *claudePartialText) observe(frame streamEvent, emit func(string)) {
	var event struct {
		Type         string
		Index        int
		Delta        struct{ Type, Text string }
		ContentBlock struct{ Type, Text string } `json:"content_block"`
	}
	if json.Unmarshal(frame.Event, &event) != nil {
		return
	}
	var text string
	switch event.Type {
	case "message_start", "message_stop":
		for _, block := range p.merge(frame, nil) {
			emit(block.Text)
		}
	case "content_block_start":
		if event.ContentBlock.Type == "text" {
			text = event.ContentBlock.Text
		}
	case "content_block_delta":
		if event.Delta.Type == "text_delta" {
			text = event.Delta.Text
		}
	}
	if text == "" {
		return
	}
	for i := range *p {
		block := &(*p)[i]
		if block.session == frame.Session && block.parent == frame.Parent && block.index == event.Index {
			block.append(text)
			return
		}
	}
	const maxPartialBlocks = 16
	if len(*p) == maxPartialBlocks {
		for _, block := range (*p)[0].blocks() {
			emit(block.Text)
		}
		*p = (*p)[1:]
	}
	block := claudePartialBlock{session: frame.Session, parent: frame.Parent, index: event.Index}
	block.append(text)
	*p = append(*p, block)
}

func (b *claudePartialBlock) append(text string) {
	if b.truncated {
		return
	}
	room := maxConsoleEventBytes - len(b.text)
	if len(text) > room {
		for room > 0 && !utf8.RuneStart(text[room]) {
			room--
		}
		text = text[:room]
		b.truncated = true
	}
	b.text += text
}

func (b claudePartialBlock) blocks() []contentBlock {
	blocks := []contentBlock{{Type: "text", Text: b.text}}
	if b.truncated {
		blocks = append(blocks, contentBlock{Type: "text", Text: "[Claude partial text exceeded the console preview limit]"})
	}
	return blocks
}

func (p *claudePartialText) merge(frame streamEvent, blocks []contentBlock) []contentBlock {
	// Match each full text block once. Two separate blocks may contain the
	// same words, and nested tool streams may advance independently.
	next := 0
	remaining := (*p)[:0]
	var merged []contentBlock
	for _, partial := range *p {
		if partial.session != frame.Session || partial.parent != frame.Parent {
			remaining = append(remaining, partial)
			continue
		}
		matched := false
		for i := next; i < len(blocks); i++ {
			if blocks[i].Type == "text" && strings.HasPrefix(blocks[i].Text, partial.text) {
				merged = append(merged, blocks[next:i+1]...)
				next, matched = i+1, true
				break
			}
		}
		if !matched {
			merged = append(merged, partial.blocks()...)
		}
	}
	*p = remaining
	return append(merged, blocks[next:]...)
}

func (p *claudePartialText) finishAll(emit func(string)) {
	for _, block := range *p {
		for _, part := range block.blocks() {
			emit(part.Text)
		}
	}
	*p = nil
}
