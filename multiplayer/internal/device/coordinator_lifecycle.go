package device

import (
	"context"
	"errors"
	"net/http"
	"net/url"
	"time"

	"agentcommander.network/pilot/internal/actions"
	"agentcommander.network/pilot/internal/control"
	"agentcommander.network/pilot/internal/identity"
)

// Refresh coordinator availability alongside the receive lease. A failed local
// read or relay update is retried without changing the last confirmed state.
func (a *Agent) syncCoordinatorInboxes(ctx context.Context, who identity.Session, lease control.Lease) {
	published := make(map[string]bool)
	for ctx.Err() == nil {
		session, err := a.getSession(ctx)
		if err != nil || session.User != who.User || session.Device != who.Device {
			return
		}
		a.publishCoordinatorInboxes(ctx, session, lease, published)
		if !wait(ctx, 15*time.Second) {
			return
		}
	}
}

func (a *Agent) publishCoordinatorInboxes(ctx context.Context, session identity.Session, lease control.Lease, published map[string]bool) {
	cfg := a.localConfig(session)
	for _, resource := range cfg.Resources {
		if !resource.Coordinator {
			continue
		}
		check, cancel := context.WithTimeout(ctx, 2*time.Second)
		ended, err := actions.CoordinatorInboxEnded(check, cfg.CommanderSocket, resource)
		cancel()
		last, known := published[resource.ID]
		if err != nil || (known && last == ended) {
			continue
		}
		path := "/v1/resources/" + url.PathEscape(resource.ID) + "/coordinator-inbox"
		body := proof(lease)
		body["ended"] = ended
		update, cancel := context.WithTimeout(ctx, 3*time.Second)
		err = a.remote(update, session, http.MethodPut, path, body, nil)
		cancel()
		if err == nil {
			published[resource.ID] = ended
		}
		var refusal statusError
		if errors.As(err, &refusal) && refusal.code == http.StatusNotFound {
			// An older relay does not support status publishing. Incoming
			// messages still get an authoritative receipt from this device.
			return
		}
	}
}
