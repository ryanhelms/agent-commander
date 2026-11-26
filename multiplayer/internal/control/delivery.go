package control

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"net/http"
	"slices"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

type Addressed struct {
	ID        string          `json:"id"`
	Device    string          `json:"device"`
	Resource  string          `json:"resource"`
	Action    string          `json:"action"`
	Envelope  json.RawMessage `json:"envelope"`
	ExpiresAt time.Time       `json:"expires_at"`
}
type Child struct {
	Addressed
	Parent       string          `json:"parent"`
	Sender       string          `json:"sender"`
	SenderDevice string          `json:"sender_device"`
	Owner        string          `json:"owner"`
	Status       string          `json:"status"`
	Result       json.RawMessage `json:"result,omitempty"`
	// GrantGroup identifies the source debited by a successful execution claim.
	GrantGroup string `json:"grantGroup,omitempty"`
}
type Submission struct {
	ID       string  `json:"id"`
	Children []Child `json:"children"`
}

const childFields = `id,device,resource,action,envelope,expires_at,parent,sender,sender_device,owner_id,CASE WHEN status='pending' AND expires_at<=now() THEN 'expired' ELSE status END,result`

const activeChildGrant = `EXISTS(SELECT FROM mp_available_actions g
	WHERE g.resource=c.resource AND g.grantee=c.sender AND g.action=c.action)`

const denyUnavailableChildren = `UPDATE mp_children c SET status='denied'
	WHERE c.status='pending' AND c.expires_at>statement_timestamp() AND NOT ` + activeChildGrant

func scanChild(row pgx.Row) (Child, error) {
	var c Child
	err := row.Scan(&c.ID, &c.Device, &c.Resource, &c.Action, &c.Envelope, &c.ExpiresAt, &c.Parent, &c.Sender, &c.SenderDevice, &c.Owner, &c.Status, &c.Result)
	return c, err
}
func scanChildren(rows pgx.Rows) ([]Child, error) {
	defer rows.Close()
	children := []Child{}
	for rows.Next() {
		c, err := scanChild(rows)
		if err != nil {
			return nil, err
		}
		children = append(children, c)
	}
	return children, rows.Err()
}

// Verify the compact JWE wire shape, leaving cryptographic verification to the addressed device.
func sealed(raw json.RawMessage) bool {
	var compact string
	if len(raw) > 768<<10 || json.Unmarshal(raw, &compact) != nil {
		return false
	}
	parts := strings.Split(compact, ".")
	if len(parts) != 5 {
		return false
	}
	for i, s := range parts {
		if s == "" && i != 1 {
			return false
		}
		for _, c := range s {
			if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_' || c == '-') {
				return false
			}
		}
	}
	return true
}
func validChild(v Addressed) bool {
	return identifier.MatchString(v.ID) && identifier.MatchString(v.Device) && identifier.MatchString(v.Resource) && identifier.MatchString(v.Action) && sealed(v.Envelope)
}
func (s *Service) submit(ctx context.Context, p Principal, r *http.Request) (any, error) {
	var in struct {
		ID       string      `json:"id"`
		Children []Addressed `json:"children"`
	}
	if err := body(r, &in); err != nil {
		return nil, err
	}
	if !identifier.MatchString(in.ID) || len(in.Children) < 1 || len(in.Children) > 32 {
		return nil, bad("provide a submission ID and 1–32 addressed children")
	}
	ids := map[string]bool{}
	slots := map[[2]string]bool{}
	for i := range in.Children {
		c := &in.Children[i]
		key := [2]string{c.Resource, c.Action}
		if !validChild(*c) || ids[c.ID] || slots[key] {
			return nil, bad("invalid or duplicate addressed child")
		}
		ids[c.ID] = true
		slots[key] = true
		c.ExpiresAt = c.ExpiresAt.UTC().Truncate(time.Microsecond)
	}
	slices.SortFunc(in.Children, func(a, b Addressed) int { return strings.Compare(a.ID, b.ID) })
	wire, err := json.Marshal(in)
	if err != nil {
		return nil, err
	}
	digest := sha256.Sum256(wire)
	err = s.write(ctx, func(tx pgx.Tx) error {
		if err := s.requireDevice(ctx, tx, p); err != nil {
			return err
		}
		tag, err := tx.Exec(ctx, `INSERT INTO mp_submissions(sender,parent,sender_device,digest) VALUES($1,$2,$3,$4) ON CONFLICT(sender,parent) DO NOTHING`, p.User, in.ID, p.Device, digest[:])
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			var old []byte
			var device string
			if err := tx.QueryRow(ctx, "SELECT digest,sender_device FROM mp_submissions WHERE sender=$1 AND parent=$2", p.User, in.ID).Scan(&old, &device); err != nil {
				return err
			}
			if device != p.Device || !bytes.Equal(old, digest[:]) {
				return conflict("submission ID already binds a different intent")
			}
			return nil
		}
		for _, c := range in.Children {
			var owner string
			if c.ExpiresAt.IsZero() || !c.ExpiresAt.After(time.Now()) || time.Until(c.ExpiresAt) > 7*24*time.Hour {
				return bad("child expiry must be within seven days")
			}
			err = tx.QueryRow(ctx, `SELECT r.owner_id FROM mp_resources r JOIN mp_available_actions g ON g.resource=r.id AND g.grantee=$1
			WHERE r.id=$2 AND r.device=$3 AND $4=g.action AND $4=ANY(r.actions) FOR SHARE OF r`, p.User, c.Resource, c.Device, c.Action).Scan(&owner)
			if errors.Is(err, pgx.ErrNoRows) {
				return forbidden()
			}
			if err != nil {
				return err
			}
			if err := s.requireDevice(ctx, tx, Principal{User: owner, Device: c.Device}); err != nil {
				return err
			}
			_, err = tx.Exec(ctx, `INSERT INTO mp_children(id,parent,sender,sender_device,owner_id,device,resource,action,envelope,expires_at,status)
			VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9::jsonb,$10,'pending')`, c.ID, in.ID, p.User, p.Device, owner, c.Device, c.Resource, c.Action, string(c.Envelope), c.ExpiresAt)
			if err != nil {
				return err
			}
			if _, err = tx.Exec(ctx, "INSERT INTO mp_outbox(id) VALUES($1)", c.ID); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return s.getSubmission(ctx, p, in.ID)
}
func (s *Service) submission(ctx context.Context, p Principal, r *http.Request) (any, error) {
	return s.getSubmission(ctx, p, r.PathValue("id"))
}
func (s *Service) getSubmission(ctx context.Context, p Principal, id string) (any, error) {
	const owner = `sender=$1 AND sender_device=$2 AND parent=$3`
	var out []Child
	err := s.write(ctx, func(tx pgx.Tx) error {
		// The sender can settle a denial even while the recipient is offline.
		if _, err := tx.Exec(ctx, denyUnavailableChildren+` AND `+owner, p.User, p.Device, id); err != nil {
			return err
		}
		rows, err := tx.Query(ctx, `SELECT `+childFields+` FROM mp_children WHERE `+owner+` ORDER BY id`, p.User, p.Device, id)
		if err != nil {
			return err
		}
		out, err = scanChildren(rows)
		return err
	})
	if err == nil && len(out) == 0 {
		return nil, missing()
	}
	return Submission{id, out}, err
}
func (s *Service) claim(ctx context.Context, p Principal, r *http.Request) (any, error) {
	var in leaseProof
	if err := body(r, &in); err != nil {
		return nil, err
	}
	var child Child
	claimed := false
	err := s.write(ctx, func(tx pgx.Tx) error {
		claimed = false
		if err := s.guardLease(ctx, tx, p, in); err != nil {
			return err
		}
		var err error
		child, err = scanChild(tx.QueryRow(ctx, "SELECT "+childFields+" FROM mp_children WHERE id=$1 AND device=$2 AND owner_id=$3 FOR UPDATE", r.PathValue("id"), p.Device, p.User))
		if err != nil {
			return err
		}
		if child.Status != "pending" {
			return nil
		}
		source, allowed, err := consume(ctx, tx, child)
		if err != nil {
			return err
		}
		if !allowed {
			return tx.QueryRow(ctx, `UPDATE mp_children SET status=CASE WHEN expires_at<=clock_timestamp()
				THEN 'expired' ELSE 'denied' END WHERE id=$1 RETURNING status`, child.ID).Scan(&child.Status)
		}
		_, err = tx.Exec(ctx, "UPDATE mp_children SET status='processing',grant_source=$2 WHERE id=$1", child.ID, source)
		if err != nil {
			return err
		}
		child.Status = "processing"
		child.GrantGroup = source
		claimed = true
		// A final use can settle siblings from other submissions. A later grant
		// extension cannot revive them, and polling clients can stop waiting.
		return denyUnavailableForGrant(ctx, tx, child.Resource, child.Sender)
	})
	return map[string]any{"claimed": claimed, "child": child}, err
}
func (s *Service) receipt(ctx context.Context, p Principal, r *http.Request) (any, error) {
	var in struct {
		leaseProof
		Status string          `json:"status"`
		Result json.RawMessage `json:"result"`
	}
	if err := body(r, &in); err != nil {
		return nil, err
	}
	if !slices.Contains([]string{"completed", "declined", "uncertain"}, in.Status) || !sealed(in.Result) {
		return nil, bad("invalid receipt status or sealed result")
	}
	var child Child
	err := s.write(ctx, func(tx pgx.Tx) error {
		if err := s.guardLease(ctx, tx, p, in.leaseProof); err != nil {
			return err
		}
		var err error
		child, err = scanChild(tx.QueryRow(ctx, "SELECT "+childFields+" FROM mp_children WHERE id=$1 AND device=$2 AND owner_id=$3 FOR UPDATE", r.PathValue("id"), p.Device, p.User))
		if err != nil {
			return err
		}
		if child.Status == in.Status && bytes.Equal(child.Result, in.Result) {
			return nil
		}
		// A purged receipt can still identify an exact retry. In particular,
		// an uncertain receipt stays distinct from a lease lost before receipt.
		if len(child.Result) == 0 && (child.Status == in.Status || child.Status == "uncertain") {
			var matches bool
			err := tx.QueryRow(ctx, `SELECT status=$2 AND receipt_digest=sha256(convert_to($3::jsonb::text,'UTF8'))
				FROM mp_children WHERE id=$1 AND receipt_digest IS NOT NULL`, child.ID, in.Status, string(in.Result)).Scan(&matches)
			switch {
			case err == nil && matches:
				return nil
			case err == nil:
				return conflict("operation already has a different outcome")
			case !errors.Is(err, pgx.ErrNoRows):
				return err
			}
		}
		if child.Status != "processing" && !(child.Status == "uncertain" && len(child.Result) == 0) {
			return conflict("operation already has a different outcome or has not been claimed")
		}
		_, err = tx.Exec(ctx, "UPDATE mp_children SET result=$2::jsonb,status=$3,completed_at=clock_timestamp() WHERE id=$1", child.ID, string(in.Result), in.Status)
		child.Result = in.Result
		child.Status = in.Status
		return err
	})
	return child, err
}
