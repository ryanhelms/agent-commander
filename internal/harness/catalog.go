// Package harness lists the AI harnesses this machine can run, probes their
// install and sign-in state, and watches what that state depends on.
package harness

import (
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
)

//go:embed harnesses.json
var embeddedCatalog []byte

// Entry is one harness in the catalog. Commands are argv lists and never pass through a shell,
// except InstallScript, which is the vendor's published install line.
type Entry struct {
	ID            string   `json:"id"`
	Name          string   `json:"name"`
	Vendor        string   `json:"vendor"`
	Kind          string   `json:"kind"`
	Group         string   `json:"group"`
	Website       string   `json:"website,omitempty"`
	Managed       bool     `json:"managed,omitempty"`
	Verified      bool     `json:"verified,omitempty"`
	Binaries      []string `json:"binaries"`
	Apps          []string `json:"apps,omitempty"`
	VersionArgs   []string `json:"version_args,omitempty"`
	Install       []string `json:"install,omitempty"`
	InstallScript string   `json:"install_script,omitempty"`
	// Login holds the arguments after the binary. An empty list runs the binary
	// itself, which signs in interactively; an absent one means no login command.
	Login         []string `json:"login,omitempty"`
	Status        *Probe   `json:"status,omitempty"`
	Credentials   []string `json:"credentials,omitempty"`
	CredentialEnv []string `json:"credential_env,omitempty"`
	Watch         []string `json:"watch,omitempty"`
	// KeychainService names the login-keychain item that holds this sign-in.
	KeychainService string   `json:"keychain_service,omitempty"`
	Profile         *Profile `json:"profile,omitempty"`
	ACPAdapter      string   `json:"acp_adapter,omitempty"`
	Models          []string `json:"models,omitempty"`
}

// Probe describes a status command and how to read its result.
type Probe struct {
	Args           []string `json:"args"`
	Parse          string   `json:"parse"`
	SignedInField  string   `json:"signed_in_field,omitempty"`
	AccountField   string   `json:"account_field,omitempty"`
	PlanField      string   `json:"plan_field,omitempty"`
	MethodField    string   `json:"method_field,omitempty"`
	ExpiresField   string   `json:"expires_field,omitempty"`
	SignedOutMatch string   `json:"signed_out_match,omitempty"`
}

// Profile names a dedicated harness home that Commander uses in place of the
// user's default one, when the environment variable Env points to it.
type Profile struct {
	Env     string   `json:"env"`
	HomeEnv string   `json:"home_env"`
	Watch   []string `json:"watch,omitempty"`
}

type catalogFile struct {
	Version   int     `json:"version"`
	Harnesses []Entry `json:"harnesses"`
}

var entryID = regexp.MustCompile(`^[a-z0-9_-]{1,40}$`)

// Catalog returns the embedded catalog in its published order.
func Catalog() ([]Entry, error) { return decodeCatalog(embeddedCatalog) }

func decodeCatalog(raw []byte) ([]Entry, error) {
	var file catalogFile
	if err := json.Unmarshal(raw, &file); err != nil {
		return nil, fmt.Errorf("invalid harness catalog: %w", err)
	}
	if file.Version != 1 {
		return nil, errors.New("unsupported harness catalog version")
	}
	seen := map[string]bool{}
	for _, e := range file.Harnesses {
		if !entryID.MatchString(e.ID) || seen[e.ID] {
			return nil, fmt.Errorf("invalid or repeated harness id %q", e.ID)
		}
		seen[e.ID] = true
		if e.Name == "" || (e.Kind != "agent" && e.Kind != "runner") || len(e.Binaries) == 0 && len(e.Apps) == 0 {
			return nil, fmt.Errorf("incomplete harness entry %q", e.ID)
		}
		if p := e.Status; p != nil && (len(p.Args) == 0 || p.Parse != "exit" && p.Parse != "json" && p.Parse != "text") {
			return nil, fmt.Errorf("invalid status probe for %q", e.ID)
		}
	}
	return file.Harnesses, nil
}
