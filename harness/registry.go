// Package harness registers portable Go session adapters linked into agentctl.
// Independently installed executables use ACP v1 and do not import this package.
package harness

import (
	"context"
	"errors"
	"fmt"
	"io"
	"regexp"
	"sync"

	agentacp "agent-acp.local/sdks/go"
	model "agent-acp.local/sdks/go/model"
	"agent-acp.local/sdks/go/runtime"
)

// Runtime owns one runner's resources. Close releases its live subscriptions.
type Runtime interface {
	agentacp.Runtime
	io.Closer
}

// Adapter supplies a fresh runtime for each live worker. ReadHistory is optional
// and must read only the named session in cwd without opening a live session.
type Adapter struct {
	ID, Version string
	Open        func(runtime.Config) (Runtime, error)
	ReadHistory func(context.Context, string, *model.ReadHistoryRequest) (*model.ReadHistoryResponse, error)
}

// Instance identifies this implementation in durable worker and history handles.
func (a Adapter) Instance() string { return "local-builtin:" + a.ID + "@" + a.Version }

var (
	adapters     sync.Map
	validID      = regexp.MustCompile(`^[a-z0-9][a-z0-9_-]{0,99}$`)
	validVersion = regexp.MustCompile(`^[0-9A-Za-z][0-9A-Za-z._+-]{0,99}$`)
)

// Register makes the adapter selectable as builtin:<id>. Call it from the
// linked adapter's init so the service and tmux runner share its registration.
func Register(a Adapter) error {
	if !validID.MatchString(a.ID) || !validVersion.MatchString(a.Version) || a.Open == nil {
		return errors.New("a built-in adapter requires a valid ID, version and Open constructor")
	}
	if _, loaded := adapters.LoadOrStore(a.ID, a); loaded {
		return fmt.Errorf("built-in adapter %q is already registered", a.ID)
	}
	return nil
}

func Lookup(id string) (Adapter, bool) {
	value, ok := adapters.Load(id)
	if !ok {
		return Adapter{}, false
	}
	return value.(Adapter), true
}
