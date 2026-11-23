APP = dist/Agent Commander.app
MACOS = $(APP)/Contents/MacOS
CONFIG ?= debug

.PHONY: app cli test smoke run

app: cli
	swift build -c $(CONFIG) --product AgentCommander
	mkdir -p "$(MACOS)"
	cp "$$(swift build -c $(CONFIG) --show-bin-path)/AgentCommander" "$(MACOS)/AgentCommander"
	cp dist/agentctl "$(MACOS)/agentctl"
	cp packaging/Info.plist "$(APP)/Contents/Info.plist"
	codesign --force --sign - "$(MACOS)/agentctl"
	codesign --force --sign - "$(APP)"

cli:
	mkdir -p dist
	go build -o dist/agentctl ./cmd/agentctl

test:
	go test ./...

smoke:
	AGENT_COMMANDER_TEST_INTEGRATION=1 AGENT_COMMANDER_TEST_TMUX=1 go test -count=1 ./cmd/agentctl ./internal/provider

run: app
	open "$(APP)"
