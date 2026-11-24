package service

func (event ConsoleEvent) ToolFailure() string {
	switch event.Phase {
	case "failed", "declined", "cancelled", "interrupted":
		return "Tool " + event.Phase + "."
	default:
		return ""
	}
}

func (event ConsoleEvent) TerminalText() string {
	switch event.Kind {
	case "tool_call":
		line := "→ " + event.Name
		if event.Phase != "" && event.Phase != "tool_call" {
			line += " [" + event.Phase + "]"
		}
		if event.Text != "" {
			line += "\n" + event.Text
		}
		return line
	case "tool_update":
		line := "Tool " + event.ToolID
		if event.Phase != "" && event.Phase != "tool_call_update" {
			line += " [" + event.Phase + "]"
		}
		if event.Text != "" {
			line += "\n" + event.Text
		}
		return line
	case "tool_result":
		if event.Text == "" {
			if failure := event.ToolFailure(); failure != "" {
				return failure
			}
			return "Tool " + event.ToolID + " completed."
		}
		return event.Text
	default:
		return event.Text
	}
}
