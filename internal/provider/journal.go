package provider

import (
	"bufio"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"

	model "agent-acp.local/sdks/go/model"
)

const maxJournalRecord = 1 << 20

var errJournalIncomplete = errors.New("native journal ends with a partial record")

type journalCursor struct {
	Scope  string `json:"scope"`
	Offset int64  `json:"offset"`
	Part   int    `json:"part,omitempty"`
}

func (c journalCursor) encode() string {
	data, _ := json.Marshal(c)
	return base64.RawURLEncoding.EncodeToString(data)
}

func readJournalLine(ctx context.Context, input *bufio.Reader) ([]byte, int64, error) {
	var data []byte
	var size int64
	for {
		if err := ctx.Err(); err != nil {
			return nil, size, err
		}
		chunk, err := input.ReadSlice('\n')
		size += int64(len(chunk))
		if size <= maxJournalRecord {
			data = append(data, chunk...)
		}
		if errors.Is(err, bufio.ErrBufferFull) {
			continue
		}
		if errors.Is(err, io.EOF) && size != 0 {
			return nil, size, errJournalIncomplete
		}
		if size > maxJournalRecord {
			data = nil
		}
		return data, size, err
	}
}

func readJournalPage(ctx context.Context, input *bufio.Reader, ref *model.SessionRef, position journalCursor, limit uint32, decode func([]byte) []*model.Observation) (*model.ReadHistoryResponse, error) {
	if limit == 0 {
		limit = 100
	}
	page := &model.ReadHistoryResponse{}
	var bytesRead int64
	for uint32(len(page.Observations)) < limit && bytesRead < 4*maxJournalRecord {
		raw, size, err := readJournalLine(ctx, input)
		if errors.Is(err, errJournalIncomplete) {
			gap := journalGap(err.Error())
			gap.Session, gap.Cursor = ref, position.encode()
			page.Observations = append(page.Observations, gap)
			break
		}
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, err
		}
		records := decode(raw)
		if position.Part > 0 && position.Part >= len(records) {
			return nil, errors.New("native journal record changed since the last page")
		}
		for position.Part < len(records) && uint32(len(page.Observations)) < limit {
			observation := records[position.Part]
			position.Part++
			observation.Session = ref
			next := position
			if next.Part == len(records) {
				next.Part, next.Offset = 0, next.Offset+size
			}
			observation.Cursor = next.encode()
			page.Observations = append(page.Observations, observation)
		}
		if position.Part < len(records) {
			page.NextCursor = position.encode()
			return page, nil
		}
		position.Part, position.Offset = 0, position.Offset+size
		bytesRead += size
	}
	if _, err := input.Peek(1); err == nil {
		page.NextCursor = position.encode()
	} else if !errors.Is(err, io.EOF) {
		return nil, err
	}
	return page, nil
}

func journalGap(reason string) *model.Observation {
	return &model.Observation{Event: &model.Observation_Gap{Gap: &model.HistoryGap{Reason: reason}}}
}
