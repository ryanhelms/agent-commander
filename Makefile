APP = dist/Agent Commander.app
MACOS = $(APP)/Contents/MacOS
RESOURCES = $(APP)/Contents/Resources
SWIFT_RESOURCES = AgentCommander_AgentCommander.bundle
CONFIG ?= debug

.PHONY: app cli test smoke run

app: cli
	swift build -c $(CONFIG) --product AgentCommander
	mkdir -p "$(MACOS)" "$(RESOURCES)"
	bin_path="$$(swift build -c $(CONFIG) --show-bin-path)" && \
		cp "$$bin_path/AgentCommander" "$(MACOS)/AgentCommander" && \
		ditto "$$bin_path/$(SWIFT_RESOURCES)" "$(RESOURCES)/$(SWIFT_RESOURCES)"
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
