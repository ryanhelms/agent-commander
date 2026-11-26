package control

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"slices"
	"time"

	"github.com/jackc/pgx/v5"
)

// DirectoryEnabled accepts the on/off labels used by policy editors as well as JSON booleans.
type DirectoryEnabled bool

func (d *DirectoryEnabled) UnmarshalJSON(data []byte) error {
	switch string(data) {
	case "true", `"on"`:
		*d = true
	case "false", `"off"`:
		*d = false
	default:
		return bad("directory must be on or off")
	}
	return nil
}

type Policy struct {
	KnowledgeDefault     string           `json:"knowledgeDefault"`
	KnowledgeWidest      string           `json:"knowledgeWidest"`
	ReputationVisibility string           `json:"reputationVisibility"`
	Directory            DirectoryEnabled `json:"directory"`
	MaxGrantDays         int32            `json:"maxGrantDays"`
	MaxBudgetTokens      int64            `json:"maxBudgetTokens"`
	RetentionDays        int32            `json:"retentionDays"`
}

const policyColumns = "knowledge_default,knowledge_widest,reputation_visibility,directory,max_grant_days,max_budget_tokens,retention_days"

func (p Policy) validate() error {
	def, widest := knowledgeScopeRank(p.KnowledgeDefault), knowledgeScopeRank(p.KnowledgeWidest)
	if def < 0 || widest < def {
		return bad("knowledgeDefault must be an allowed scope within knowledgeWidest")
	}
	if !slices.Contains([]string{"owner", "users", "friends", "server"}, p.ReputationVisibility) {
		return bad("unknown reputationVisibility")
	}
	if p.MaxGrantDays < 0 || p.MaxBudgetTokens < 0 || p.RetentionDays < 1 {
		return bad("grant limits must be nonnegative and retentionDays must be positive")
	}
	return nil
}

func (s *Service) policy(ctx context.Context, p Principal, _ *http.Request) (any, error) {
	var current Policy
	var admin bool
	err := s.pool.QueryRow(ctx, "SELECT $1=ANY(admin_hashes),"+policyColumns+" FROM mp_membership_policy CROSS JOIN mp_policy", p.EmailHash).
		Scan(&admin, &current.KnowledgeDefault, &current.KnowledgeWidest, &current.ReputationVisibility,
			&current.Directory, &current.MaxGrantDays, &current.MaxBudgetTokens, &current.RetentionDays)
	if err == nil && !admin {
		return nil, forbidden()
	}
	return current, err
}

func (s *Service) setPolicy(ctx context.Context, p Principal, r *http.Request) (any, error) {
	var edit json.RawMessage
	if err := body(r, &edit); err != nil {
		return nil, err
	}
	if len(edit) == 0 || edit[0] != '{' {
		return nil, bad("provide a policy object")
	}
	var updated Policy
	err := s.write(ctx, func(tx pgx.Tx) error {
		if err := s.requireDevice(ctx, tx, p); err != nil {
			return err
		}
		access, err := readAccess(ctx, tx, p)
		if err != nil {
			return err
		}
		if !access.Admin {
			return forbidden()
		}
		// Apply partial settings to the locked policy so concurrent edits compose.
		err = tx.QueryRow(ctx, "SELECT "+policyColumns+" FROM mp_policy FOR UPDATE").Scan(
			&updated.KnowledgeDefault, &updated.KnowledgeWidest, &updated.ReputationVisibility,
			&updated.Directory, &updated.MaxGrantDays, &updated.MaxBudgetTokens, &updated.RetentionDays)
		if err != nil {
			return err
		}
		decoder := json.NewDecoder(bytes.NewReader(edit))
		decoder.DisallowUnknownFields()
		if err := decoder.Decode(&updated); err != nil {
			return bad("invalid policy setting")
		}
		if err := updated.validate(); err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `UPDATE mp_policy SET knowledge_default=$1,knowledge_widest=$2,
			reputation_visibility=$3,directory=$4,max_grant_days=$5,max_budget_tokens=$6,retention_days=$7`,
			updated.KnowledgeDefault, updated.KnowledgeWidest, updated.ReputationVisibility, updated.Directory,
			updated.MaxGrantDays, updated.MaxBudgetTokens, updated.RetentionDays)
		return err
	})
	return updated, err
}

// Zero retains the uncapped pilot grant policy. A zero per-action budget also
// means unlimited, so it cannot satisfy a finite relay token cap.
func checkGrantPolicy(ctx context.Context, tx pgx.Tx, g grantPolicy) error {
	var days int32
	var tokens int64
	if err := tx.QueryRow(ctx, "SELECT max_grant_days,max_budget_tokens FROM mp_policy").Scan(&days, &tokens); err != nil {
		return err
	}
	if days > 0 && g.ExpiresAt.After(time.Now().UTC().AddDate(0, 0, int(days))) {
		return bad("grant exceeds maxGrantDays")
	}
	if tokens > 0 {
		if len(g.Limits) == 0 {
			return bad("maxBudgetTokens requires an explicit action budget")
		}
		for _, limit := range g.Limits {
			if limit.BudgetTokens == 0 || limit.BudgetTokens > tokens {
				return bad("action budget exceeds maxBudgetTokens")
			}
		}
	}
	return nil
}

type PublicSettings struct {
	Membership   string `json:"membership"`
	AdminContact string `json:"adminContact"`
	Policy       Policy `json:"policy"`
}

func (s *Service) PublicSettings(ctx context.Context) (PublicSettings, error) {
	var v PublicSettings
	p := &v.Policy
	err := s.pool.QueryRow(ctx, "SELECT mode,coalesce(admins[1],''),"+policyColumns+" FROM mp_membership CROSS JOIN mp_policy").
		Scan(&v.Membership, &v.AdminContact, &p.KnowledgeDefault, &p.KnowledgeWidest, &p.ReputationVisibility,
			&p.Directory, &p.MaxGrantDays, &p.MaxBudgetTokens, &p.RetentionDays)
	return v, err
}
