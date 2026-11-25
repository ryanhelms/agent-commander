package provider

import (
	"context"
	"errors"
	"os"
	"strings"
	"sync"
	"time"

	model "agent-acp.local/sdks/go/model"
	"agent-acp.local/sdks/go/runtime"

	"agentcommander/internal/service"
)

const (
	replayCacheTTL     = 2 * time.Minute
	replayCacheBytes   = 64 << 20
	replayCacheEntries = 4
	replayLimitReason  = "ACP provider history exceeds the stopped-session replay limit."
)

type replayCacheKey struct {
	native service.NativeSession
	cwd    string
}

type replayCacheEntry struct {
	index      *runtime.ReplaySnapshot
	executable os.FileInfo
	expires    time.Time
	lastUse    uint64
}

type replayCache struct {
	mu    sync.Mutex
	items map[replayCacheKey]replayCacheEntry
	bytes int
	clock uint64
}

func (l *Local) replaySelection(native service.NativeSession) (string, acpProfile, bool) {
	name, external := strings.CutPrefix(native.HarnessInstance, "local-profile-")
	id, _, bound := strings.Cut(name, ":history-")
	profile := l.acpProfiles[id]
	return id, profile, external && bound && profile.History != nil && profile.History.Format == acpReplayHistory
}

func (l *Local) RequiresStoppedHistory(native service.NativeSession) bool {
	// The service asks this while protecting the worker state. Resolving the
	// executable is required for replay, and happens outside that state lock.
	_, _, replay := l.replaySelection(native)
	return replay
}

func (l *Local) replayProfile(native service.NativeSession) (acpProfile, bool) {
	id, profile, replay := l.replaySelection(native)
	if !replay {
		return acpProfile{}, false
	}
	executable, err := profile.executable()
	if err != nil {
		return acpProfile{}, false
	}
	// Launch has always persisted the resolved executable and arguments.
	// Use the same identity, including for sessions launched before this change.
	profile.Command = executable
	return profile, profile.instance(id) == native.HarnessInstance
}

func replayLimitPage(native service.NativeSession) *model.ReadHistoryResponse {
	return &model.ReadHistoryResponse{Observations: []*model.Observation{{
		Session: &model.SessionRef{HarnessInstance: native.HarnessInstance, SessionId: native.SessionID},
		Event:   &model.Observation_Gap{Gap: &model.HistoryGap{Reason: replayLimitReason}},
	}}}
}

func (l *Local) loadReplaySnapshot(ctx context.Context, native service.NativeSession, cwd string) (*runtime.ReplaySnapshot, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	key := replayCacheKey{native: native, cwd: cwd}
	_, executable, err := l.replayExecutable(native)
	if err != nil {
		return nil, err
	}
	if snapshot := l.replayCache.get(key, executable); snapshot != nil {
		return snapshot, ctx.Err()
	}

	select {
	case l.replaySlot <- struct{}{}:
		defer func() { <-l.replaySlot }()
	case <-ctx.Done():
		return nil, ctx.Err()
	}
	// A competing reader may have built the index or the configured shim
	// may have changed while this request waited for the single replay slot.
	profile, executable, err := l.replayExecutable(native)
	if err != nil {
		return nil, err
	}
	if snapshot := l.replayCache.get(key, executable); snapshot != nil {
		return snapshot, ctx.Err()
	}

	config := runtime.Config{
		HarnessInstance: native.HarnessInstance, WorkingDirectory: cwd,
		Command: profile.Command, Args: profile.Args, ReplayHistory: true,
	}
	configureACPActivity(&config)
	rt, err := runtime.New(config)
	if err != nil {
		return nil, err
	}
	defer rt.Close()
	ref := &model.SessionRef{HarnessInstance: native.HarnessInstance, SessionId: native.SessionID}
	snapshot, err := rt.LoadReplay(ctx, ref)
	if err != nil {
		return nil, err
	}
	_, current, err := l.replayExecutable(native)
	if err != nil || !sameReplayExecutable(executable, current) {
		return nil, errors.New("ACP replay executable changed during history loading")
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	l.replayCache.put(key, replayCacheEntry{index: snapshot, executable: executable, expires: time.Now().Add(replayCacheTTL)})
	return snapshot, nil
}

func (l *Local) replayExecutable(native service.NativeSession) (acpProfile, os.FileInfo, error) {
	profile, valid := l.replayProfile(native)
	if !valid {
		return acpProfile{}, nil, errors.New("ACP replay executable does not match the bound session")
	}
	file, err := os.Stat(profile.Command)
	if err != nil {
		return acpProfile{}, nil, err
	}
	return profile, file, nil
}

func sameReplayExecutable(older, newer os.FileInfo) bool {
	return os.SameFile(older, newer) && older.Size() == newer.Size() && older.ModTime().Equal(newer.ModTime())
}

func (c *replayCache) get(key replayCacheKey, executable os.FileInfo) *runtime.ReplaySnapshot {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.prune(time.Now())
	entry, exists := c.items[key]
	if !exists {
		return nil
	}
	if !sameReplayExecutable(entry.executable, executable) {
		c.remove(key, entry)
		return nil
	}
	c.clock++
	entry.lastUse = c.clock
	c.items[key] = entry
	return entry.index
}

func (c *replayCache) put(key replayCacheKey, entry replayCacheEntry) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.prune(time.Now())
	if old, exists := c.items[key]; exists {
		c.remove(key, old)
	}
	if entry.index.Size() > replayCacheBytes {
		return
	}
	for len(c.items) >= replayCacheEntries || c.bytes+entry.index.Size() > replayCacheBytes {
		var oldestKey replayCacheKey
		var oldest replayCacheEntry
		for candidate, item := range c.items {
			if oldest.index == nil || item.lastUse < oldest.lastUse {
				oldestKey, oldest = candidate, item
			}
		}
		c.remove(oldestKey, oldest)
	}
	if c.items == nil {
		c.items = make(map[replayCacheKey]replayCacheEntry)
	}
	c.clock++
	entry.lastUse = c.clock
	c.items[key] = entry
	c.bytes += entry.index.Size()
}

func (c *replayCache) prune(now time.Time) {
	for key, entry := range c.items {
		if !now.Before(entry.expires) {
			c.remove(key, entry)
		}
	}
}

func (c *replayCache) remove(key replayCacheKey, entry replayCacheEntry) {
	c.bytes -= entry.index.Size()
	delete(c.items, key)
}

func (c *replayCache) invalidate(native service.NativeSession) {
	c.mu.Lock()
	defer c.mu.Unlock()
	for key, entry := range c.items {
		if key.native == native {
			c.remove(key, entry)
		}
	}
}
