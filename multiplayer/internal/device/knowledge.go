package device

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
)

var knowledgePlaceholder = regexp.MustCompile(`\$\{[A-Za-z_][A-Za-z0-9_]*\}`)

func knowledgePassword(ctx context.Context, name string) (string, error) {
	if runtime.GOOS != "darwin" {
		return "", os.ErrNotExist
	}
	b, err := exec.CommandContext(ctx, "/usr/bin/security", "find-generic-password", "-s", "Agent Commander Knowledge", "-a", name, "-w").Output()
	var exit *exec.ExitError
	// security returns the low byte of errSecItemNotFound (-25300).
	if errors.As(err, &exit) && exit.ExitCode() == 44 {
		return "", os.ErrNotExist
	}
	if err != nil {
		return "", fmt.Errorf("read Keychain account %s: %w", name, err)
	}
	return strings.TrimSuffix(string(b), "\n"), nil
}

func installKnowledge(ctx context.Context, in input, lookup func(context.Context, string) (string, error)) (any, error) {
	var item struct{ Kind, Name, Content string }
	if json.Unmarshal(in.Item, &item) != nil || item.Name == "" {
		return nil, errors.New("invalid knowledge item")
	}
	switch item.Kind {
	case "prompt", "instructions", "summary":
		return map[string]string{"content": item.Content}, nil
	case "skill":
		name := filepath.Base(strings.ReplaceAll(item.Name, " ", "-"))
		if !filepath.IsLocal(name) || name == "." {
			return nil, errors.New("invalid skill name")
		}
		home, err := os.UserHomeDir()
		if err != nil {
			return nil, err
		}
		dir := filepath.Join(home, ".claude", "skills", name)
		if err = os.MkdirAll(dir, 0755); err != nil {
			return nil, err
		}
		path := filepath.Join(dir, "SKILL.md")
		return map[string]string{"installed": path}, os.WriteFile(path, []byte(item.Content), 0644)
	case "mcp":
		if !filepath.IsAbs(in.Destination) {
			return nil, errors.New("choose where to save this item")
		}
		values := map[string]string{}
		missing := []string{}
		jsonConfig := json.Valid([]byte(item.Content))
		for _, placeholder := range knowledgePlaceholder.FindAllString(item.Content, -1) {
			if _, ok := values[placeholder]; ok {
				continue
			}
			name := placeholder[2 : len(placeholder)-1]
			value, err := lookup(ctx, name)
			switch {
			case errors.Is(err, os.ErrNotExist):
				missing = append(missing, name)
				value = placeholder
			case err != nil:
				return nil, err
			case jsonConfig:
				// A placeholder in valid JSON lies inside a string literal.
				quoted, _ := json.Marshal(value)
				value = string(quoted[1 : len(quoted)-1])
			}
			values[placeholder] = value
		}
		content := knowledgePlaceholder.ReplaceAllStringFunc(item.Content, func(match string) string { return values[match] })
		err := writePrivateFile(in.Destination, func(w io.Writer) error {
			_, err := io.WriteString(w, content)
			return err
		})
		return map[string]any{"installed": in.Destination, "missing": missing}, err
	default:
		return nil, errors.New("unknown knowledge kind")
	}
}
