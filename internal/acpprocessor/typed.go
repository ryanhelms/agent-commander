package acpprocessor

import (
	"encoding/json"

	model "agent-acp.local/sdks/go/model"
)

// TypedUpdate rebuilds the ACP session update behind an SDK SessionUpdate or
// MessageContent observation and decodes it like an original. Use it only when
// the observation carries no original. Media bytes are not retained by the
// typed form, so a rebuilt image or audio block has empty data.
func TypedUpdate(obs *model.Observation) (Update, bool) {
	var update map[string]any
	if change := obs.GetSessionUpdate(); change != nil {
		update = sessionChangeJSON(change)
	} else if content := obs.GetContent(); content != nil {
		update = messageContentJSON(content)
	}
	if update == nil {
		return Update{}, false
	}
	raw, err := json.Marshal(update)
	if err != nil {
		return Update{}, false
	}
	return Decode(raw), true
}

func sessionChangeJSON(change *model.SessionUpdate) map[string]any {
	switch {
	case change.GetPlan() != nil:
		entries := []any{}
		for _, entry := range change.GetPlan().GetEntries() {
			entries = append(entries, map[string]any{"content": entry.Content, "priority": entry.Priority, "status": entry.Status})
		}
		return map[string]any{"sessionUpdate": "plan", "entries": entries}
	case change.GetCommands() != nil:
		commands := []any{}
		for _, command := range change.GetCommands().GetCommands() {
			item := map[string]any{"name": command.Name, "description": command.Description}
			if command.InputHint != nil {
				item["input"] = map[string]any{"hint": command.GetInputHint()}
			}
			commands = append(commands, item)
		}
		return map[string]any{"sessionUpdate": "available_commands_update", "availableCommands": commands}
	case change.GetMode() != nil:
		return map[string]any{"sessionUpdate": "current_mode_update", "currentModeId": change.GetMode().GetModeId()}
	case change.GetConfiguration() != nil:
		options := []any{}
		for _, option := range change.GetConfiguration().GetOptions() {
			item := map[string]any{"type": option.Kind, "id": option.Id, "name": option.Name}
			setOptional(item, "description", option.Description)
			setOptional(item, "category", option.Category)
			switch value := option.CurrentValue.(type) {
			case *model.ConfigurationSnapshot_Option_Selected:
				item["currentValue"] = value.Selected
			case *model.ConfigurationSnapshot_Option_Enabled:
				item["currentValue"] = value.Enabled
			}
			if option.Kind == "select" {
				if len(option.Groups) > 0 {
					groups := []any{}
					for _, group := range option.Groups {
						groups = append(groups, map[string]any{"group": group.Id, "name": group.Name, "options": configChoicesJSON(group.Choices)})
					}
					item["options"] = groups
				} else {
					item["options"] = configChoicesJSON(option.Choices)
				}
			}
			options = append(options, item)
		}
		return map[string]any{"sessionUpdate": "config_option_update", "configOptions": options}
	case change.GetInfo() != nil:
		info := change.GetInfo()
		update := map[string]any{"sessionUpdate": "session_info_update"}
		switch {
		case info.ClearTitle:
			update["title"] = nil
		case info.Title != nil:
			update["title"] = info.GetTitle()
		}
		switch {
		case info.ClearUpdatedAt:
			update["updatedAt"] = nil
		case info.UpdatedAt != nil:
			update["updatedAt"] = info.GetUpdatedAt()
		}
		return update
	case change.GetUsage() != nil:
		usage := change.GetUsage()
		update := map[string]any{"sessionUpdate": "usage_update", "used": usage.Used, "size": usage.Size}
		if cost := usage.GetCost(); cost != nil {
			update["cost"] = map[string]any{"amount": cost.Amount, "currency": cost.Currency}
		}
		return update
	}
	return nil
}

func configChoicesJSON(choices []*model.ConfigurationSnapshot_Choice) []any {
	result := []any{}
	for _, choice := range choices {
		item := map[string]any{"value": choice.Value, "name": choice.Name}
		setOptional(item, "description", choice.Description)
		result = append(result, item)
	}
	return result
}

func messageContentJSON(content *model.MessageContent) map[string]any {
	kind := "agent_message_chunk"
	switch {
	case content.Thought:
		kind = "agent_thought_chunk"
	case content.Speaker == model.Speaker_SPEAKER_USER:
		kind = "user_message_chunk"
	}
	block := map[string]any{"type": content.Kind}
	switch content.Kind {
	case "text":
		block["text"] = content.Text
	case "image", "audio":
		block["mimeType"], block["data"] = content.MimeType, ""
		setOptional(block, "uri", content.Uri)
	case "resource_link":
		block["uri"], block["name"] = content.Uri, content.Name
		setOptional(block, "mimeType", content.MimeType)
		setOptional(block, "title", content.Title)
		setOptional(block, "description", content.Description)
		if content.Size != nil {
			block["size"] = content.GetSize()
		}
	case "resource":
		resource := map[string]any{"uri": content.Uri, "text": content.Text}
		setOptional(resource, "mimeType", content.MimeType)
		block["resource"] = resource
	default:
		return nil
	}
	return map[string]any{"sessionUpdate": kind, "content": block}
}

func setOptional(object map[string]any, key, value string) {
	if value != "" {
		object[key] = value
	}
}
