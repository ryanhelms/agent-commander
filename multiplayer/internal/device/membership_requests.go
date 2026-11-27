package device

import (
	"context"
	"errors"
	"net/http"

	"agentcommander.network/pilot/internal/identity"
)

// After a refused sign-in the device can ask the relay's admins to let the
// account in, without signing in again: the relay ties the request to this
// device's certificate and the refusal it recorded. See
// design/COMMANDER-NETWORK-DISCOVERY.md, "Membership requests".

func (a *Agent) setAccess(state string) {
	a.mu.Lock()
	a.access = state
	a.mu.Unlock()
}

func (a *Agent) requestMembership(ctx context.Context, note string) (any, error) {
	a.mu.Lock()
	signedIn := a.creds.Session.User != ""
	a.mu.Unlock()
	if signedIn {
		return nil, errors.New("already a member of this relay")
	}
	req, err := a.identity.RequestMembership(ctx, note)
	var status identity.HTTPError
	switch {
	case errors.As(err, &status) && status.Status == http.StatusNotFound:
		a.setAccess("")
		return nil, errors.New("sign in first; a request must follow a refused sign-in from this Mac within 15 minutes")
	case errors.As(err, &status) && status.Status == http.StatusTooManyRequests:
		// Either a recent denial or a full queue; status says which.
		if mine, e := a.identity.MyMembershipRequest(ctx); e == nil && mine.Status == "denied" {
			a.setAccess("denied")
			return nil, errors.New("the relay's admins declined a request from this account in the last day")
		}
		a.setAccess("full")
		return nil, errors.New("the relay has too many pending requests; ask an admin directly")
	case err != nil:
		return nil, err
	}
	a.setAccess(req.Status)
	return req, nil
}

func (a *Agent) membershipRequestStatus(ctx context.Context) (any, error) {
	req, err := a.identity.MyMembershipRequest(ctx)
	var status identity.HTTPError
	if errors.As(err, &status) && status.Status == http.StatusNotFound {
		return map[string]string{"status": ""}, nil
	}
	if err != nil {
		return nil, err
	}
	switch req.Status {
	case "pending", "approved", "denied":
		a.setAccess(req.Status)
	case "admitted":
		a.setAccess("")
	}
	return req, nil
}
