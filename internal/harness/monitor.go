package harness

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"sync"
	"time"
)

// Monitor keeps every harness's status current. It never runs a status command
// on a timer: once a second it compares cheap file fingerprints and re-probes
// only the harnesses whose credentials, executable or expiry changed.
type Monitor struct {
	env          Env
	entries      []Entry
	settingsPath string
	interval     time.Duration

	mu       sync.Mutex
	statuses map[string]Status
	settings map[string]Settings
	prints   map[string]string
	inFlight map[string]bool
	again    map[string]bool
	pending  map[string]bool
	subs     map[chan []Status]struct{}
	sessions *sessions

	start  sync.Once
	ready  chan struct{}
	stop   context.CancelFunc
	ctx    context.Context
	loaded bool
}

// NewMonitor reads saved settings from stateDir. Nothing runs until Start or the first read.
func NewMonitor(stateDir string, env Env) (*Monitor, error) {
	entries, err := Catalog()
	if err != nil {
		return nil, err
	}
	return newMonitor(stateDir, env, entries)
}

func newMonitor(stateDir string, env Env, entries []Entry) (*Monitor, error) {
	ctx, cancel := context.WithCancel(context.Background())
	m := &Monitor{env: env, entries: entries, settingsPath: filepath.Join(stateDir, "harness-settings.json"),
		interval: time.Second, statuses: map[string]Status{}, settings: map[string]Settings{}, prints: map[string]string{},
		inFlight: map[string]bool{}, again: map[string]bool{}, pending: map[string]bool{}, subs: map[chan []Status]struct{}{},
		ready: make(chan struct{}), ctx: ctx, stop: cancel}
	m.sessions = newSessions(stateDir, env, m.Recheck)
	raw, err := os.ReadFile(m.settingsPath)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	if len(raw) > 0 && json.Unmarshal(raw, &m.settings) != nil {
		return nil, errors.New("invalid harness settings")
	}
	return m, nil
}

// Start runs the first full check and the watch loop. It is safe to call more than once.
func (m *Monitor) Start() {
	m.start.Do(func() {
		go func() {
			m.checkAll()
			close(m.ready)
			m.watch()
		}()
	})
}

// Close stops the watch loop.
func (m *Monitor) Close() { m.stop() }

func (m *Monitor) entry(id string) (Entry, bool) {
	for _, e := range m.entries {
		if e.ID == id {
			return e, true
		}
	}
	return Entry{}, false
}

func (m *Monitor) settingsFor(id string) Settings {
	if s, ok := m.settings[id]; ok {
		return s
	}
	return Settings{Enabled: true}
}

func (m *Monitor) checkAll() {
	var wg sync.WaitGroup
	slots := make(chan struct{}, 6)
	for _, e := range m.entries {
		m.mu.Lock()
		m.prints[e.ID] = m.fingerprint(e)
		m.mu.Unlock()
		wg.Add(1)
		go func(e Entry) {
			defer wg.Done()
			slots <- struct{}{}
			defer func() { <-slots }()
			m.checkOne(e)
		}(e)
	}
	wg.Wait()
	m.mu.Lock()
	m.loaded = true
	m.mu.Unlock()
}

// checkOne probes e and publishes the result if anything other than the check time changed.
func (m *Monitor) checkOne(e Entry) {
	m.mu.Lock()
	settings := m.settingsFor(e.ID)
	m.mu.Unlock()
	next := Check(m.ctx, m.env, e, settings)
	m.publish(next)
}

func (m *Monitor) publish(next Status) {
	m.mu.Lock()
	prev, had := m.statuses[next.ID]
	next.Changed = ""
	m.statuses[next.ID] = next
	if !m.loaded {
		m.mu.Unlock()
		return
	}
	changed := changeKind(prev, next)
	if had && changed == "" {
		m.mu.Unlock()
		return
	}
	frame := m.snapshotLocked()
	for i := range frame {
		if frame[i].ID == next.ID {
			frame[i].Changed = changed
		}
	}
	for ch := range m.subs {
		select {
		case ch <- frame:
		default:
			// A slow reader gets the newest frame; drop the stale one first.
			select {
			case <-ch:
			default:
			}
			select {
			case ch <- frame:
			default:
			}
		}
	}
	m.mu.Unlock()
}

func changeKind(prev, next Status) string {
	switch {
	case prev.Installed != next.Installed || prev.Executable != next.Executable:
		return "installed"
	case !reflect.DeepEqual(prev.Auth, next.Auth):
		return "auth"
	case prev.Version != next.Version:
		return "version"
	case prev.Settings != next.Settings:
		return "settings"
	case !reflect.DeepEqual(prev.ACP, next.ACP) || prev.Install != next.Install || prev.Login != next.Login:
		return "installed"
	}
	return ""
}

func (m *Monitor) snapshotLocked() []Status {
	out := make([]Status, 0, len(m.entries))
	for _, e := range m.entries {
		if s, ok := m.statuses[e.ID]; ok {
			s.Changed = ""
			out = append(out, s)
		}
	}
	return out
}

// List waits for the first full check, then returns every harness in catalog order.
func (m *Monitor) List(ctx context.Context) ([]Status, error) {
	m.Start()
	select {
	case <-m.ready:
	case <-ctx.Done():
		return nil, ctx.Err()
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.snapshotLocked(), nil
}

// Subscribe returns the current list and a channel that carries each changed list.
func (m *Monitor) Subscribe(ctx context.Context) ([]Status, <-chan []Status, func(), error) {
	first, err := m.List(ctx)
	if err != nil {
		return nil, nil, nil, err
	}
	ch := make(chan []Status, 1)
	m.mu.Lock()
	m.subs[ch] = struct{}{}
	m.mu.Unlock()
	return first, ch, func() {
		m.mu.Lock()
		delete(m.subs, ch)
		m.mu.Unlock()
	}, nil
}

// Check re-probes one harness now and returns its status.
func (m *Monitor) Check(ctx context.Context, id string) (Status, error) {
	e, ok := m.entry(id)
	if !ok {
		return Status{}, ErrUnknown
	}
	if _, err := m.List(ctx); err != nil {
		return Status{}, err
	}
	m.checkOne(e)
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.statuses[id], nil
}

// Recheck schedules a background probe of one harness, coalescing overlapping requests.
func (m *Monitor) Recheck(id string) {
	e, ok := m.entry(id)
	if !ok {
		return
	}
	m.mu.Lock()
	if m.inFlight[id] {
		m.again[id] = true
		m.mu.Unlock()
		return
	}
	m.inFlight[id] = true
	m.mu.Unlock()
	go func() {
		for {
			m.checkOne(e)
			m.mu.Lock()
			if !m.again[id] {
				m.inFlight[id] = false
				m.mu.Unlock()
				return
			}
			m.again[id] = false
			m.mu.Unlock()
		}
	}()
}

// ErrUnknown reports a harness ID that is not in the catalog.
var ErrUnknown = errors.New("harness not found")

// UpdateSettings saves one harness's settings and publishes the change.
func (m *Monitor) UpdateSettings(ctx context.Context, id string, next Settings) (Status, error) {
	e, ok := m.entry(id)
	if !ok {
		return Status{}, ErrUnknown
	}
	if next.DefaultModel != "" && len(e.Models) > 0 && !contains(e.Models, next.DefaultModel) {
		return Status{}, fmt.Errorf("%s does not offer the model %q", e.Name, next.DefaultModel)
	}
	if len(next.DefaultModel) > 100 || strings.ContainsAny(next.DefaultModel, "\r\n\x00") {
		return Status{}, errors.New("invalid model name")
	}
	if _, err := m.List(ctx); err != nil {
		return Status{}, err
	}
	m.mu.Lock()
	m.settings[id] = next
	raw, err := json.MarshalIndent(m.settings, "", "  ")
	if err == nil {
		err = writeAtomic(m.settingsPath, raw)
	}
	status := m.statuses[id]
	m.mu.Unlock()
	if err != nil {
		return Status{}, err
	}
	status.Settings = next
	m.publish(status)
	return status, nil
}

func contains(items []string, item string) bool {
	for _, v := range items {
		if v == item {
			return true
		}
	}
	return false
}

func writeAtomic(path string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".harness-settings-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}

func (m *Monitor) watch() {
	ticker := time.NewTicker(m.interval)
	defer ticker.Stop()
	for {
		select {
		case <-m.ctx.Done():
			return
		case <-ticker.C:
			m.scan()
		}
	}
}

// minSpacing bounds how often a busy credential store can re-run one status command.
const minSpacing = 2 * time.Second

// scan re-probes each harness whose fingerprint changed or whose sign-in has expired.
func (m *Monitor) scan() {
	now := m.env.Now()
	for _, e := range m.entries {
		print := m.fingerprint(e)
		m.mu.Lock()
		if m.prints[e.ID] != print {
			m.pending[e.ID] = true
		}
		m.prints[e.ID] = print
		s := m.statuses[e.ID]
		expired := s.Auth.State == SignedIn && s.Auth.ExpiresAt != nil && !s.Auth.ExpiresAt.After(now)
		due := (m.pending[e.ID] || expired) && now.Sub(s.CheckedAt) >= minSpacing
		if due {
			m.pending[e.ID] = false
		}
		m.mu.Unlock()
		if due {
			m.Recheck(e.ID)
		}
	}
}

// fingerprint summarizes everything that can change e's state without running it:
// the resolved executables, and the watched credential files and folders.
func (m *Monitor) fingerprint(e Entry) string {
	var b strings.Builder
	for _, name := range e.Binaries {
		path := m.env.lookPath(name)
		b.WriteString(name + "=" + path + statPrint(path) + ";")
	}
	if e.ACPAdapter != "" {
		path := m.env.adapterPath(e.ACPAdapter)
		b.WriteString(e.ACPAdapter + "=" + path + statPrint(path) + ";")
	}
	if e.Profile != nil {
		b.WriteString("profile=" + m.env.profileHome(e) + ";")
	}
	for _, key := range e.CredentialEnv {
		if m.env.Getenv(key) != "" {
			b.WriteString(key + ";")
		}
	}
	for _, path := range m.env.WatchPaths(e) {
		b.WriteString(path + statPrint(path))
		if info, err := os.Stat(path); err == nil && info.IsDir() {
			names, _ := os.ReadDir(path)
			list := make([]string, 0, len(names))
			for _, n := range names {
				list = append(list, n.Name()+statPrint(filepath.Join(path, n.Name())))
			}
			sort.Strings(list)
			b.WriteString("[" + strings.Join(list, ",") + "]")
		}
		b.WriteString(";")
	}
	return b.String()
}

func statPrint(path string) string {
	if path == "" {
		return ""
	}
	info, err := os.Stat(path)
	if err != nil {
		return ":absent"
	}
	return fmt.Sprintf(":%d:%d", info.Size(), info.ModTime().UnixNano())
}
