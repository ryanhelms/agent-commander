// Package sharing defines the public metadata for resources published on a relay.
package sharing

type Capabilities struct {
	Harness      string   `json:"harness,omitempty"`
	Model        string   `json:"model,omitempty"`
	Slots        *int     `json:"slots,omitempty"`
	Tools        []string `json:"tools,omitzero"`
	Environments []string `json:"environments,omitzero"`
}

// WithDefaults fills omitted fields without modifying either profile. A supplied
// empty tools or environments list clears that field.
func (c *Capabilities) WithDefaults(defaults *Capabilities) *Capabilities {
	if c == nil {
		return defaults
	}
	if defaults == nil {
		return c
	}
	merged := *c
	if merged.Harness == "" {
		merged.Harness = defaults.Harness
	}
	if merged.Model == "" {
		merged.Model = defaults.Model
	}
	if merged.Slots == nil {
		merged.Slots = defaults.Slots
	}
	if merged.Tools == nil {
		merged.Tools = defaults.Tools
	}
	if merged.Environments == nil {
		merged.Environments = defaults.Environments
	}
	return &merged
}
