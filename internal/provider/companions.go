package provider

import "agentcommander/internal/toolregistry"

func (j job) companionScope() toolregistry.CompanionScope {
	return toolregistry.CompanionScope{
		ProjectPath: j.Worker.Path, Role: j.Worker.Role, Host: j.Worker.Host,
		Interactive: !j.FocusedProof && j.SSH == nil && j.Codex == nil &&
			j.RegisteredACP == nil && j.BuiltinInstance == "" && (j.Claude != "" || j.Harness == "claude"),
	}
}

func (j job) companionBindings() []toolregistry.CompanionBinding {
	if !j.companionScope().Eligible() {
		return nil
	}
	if j.Companions != nil {
		return j.Companions
	}
	// A pending pre-registry job already carries its verified Devflow path.
	return []toolregistry.CompanionBinding{DevflowCompanion().Binding(j.DevflowUI)}
}
