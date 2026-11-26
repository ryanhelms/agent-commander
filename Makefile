APP = dist/Agent Commander.app
MACOS = $(APP)/Contents/MacOS
RESOURCES = $(APP)/Contents/Resources
SWIFT_RESOURCES = AgentCommander_AgentCommander.bundle
CONFIG ?= debug
CODE_SIGN_IDENTITY ?= -
NATIVE_TEST_JOBS ?= 3

PG_FORMULA ?= postgresql@17
# Resolves the agent-acp SDK checkouts from any checkout or worktree.
SDK_GOWORK := $(shell sh packaging/sdk-workspace.sh)

.PHONY: app cli network relay postgres sdk-paths pilot-macos test test-native test-multiplayer-docker smoke run reload dev

app: cli network relay postgres
	swift build -c $(CONFIG) --product AgentCommander
	mkdir -p "$(MACOS)" "$(RESOURCES)"
	bin_path="$$(swift build -c $(CONFIG) --show-bin-path)" && \
		cp "$$bin_path/AgentCommander" "$(MACOS)/AgentCommander" && \
		ditto "$$bin_path/$(SWIFT_RESOURCES)" "$(RESOURCES)/$(SWIFT_RESOURCES)" && \
		ditto "$$bin_path/SwiftTerm_SwiftTerm.bundle" "$(RESOURCES)/SwiftTerm_SwiftTerm.bundle"
	cp dist/agentctl "$(MACOS)/agentctl"
	cp dist/commander-network "$(MACOS)/commander-network"
	cp dist/commander-relay "$(MACOS)/commander-relay"
	rm -rf "$(RESOURCES)/postgres" && ditto dist/postgres "$(RESOURCES)/postgres"
	cp packaging/Info.plist "$(APP)/Contents/Info.plist"
	codesign --force --sign "$(CODE_SIGN_IDENTITY)" "$(MACOS)/agentctl"
	codesign --force --sign "$(CODE_SIGN_IDENTITY)" "$(MACOS)/commander-network"
	codesign --force --sign "$(CODE_SIGN_IDENTITY)" "$(MACOS)/commander-relay"
	codesign --force --sign "$(CODE_SIGN_IDENTITY)" "$(APP)"

pilot-macos:
	python3 packaging/macos-pilot.py --sign "$(CODE_SIGN_IDENTITY)" --sdk-release "$(SDK_RELEASE)" --notary-profile "$(PILOT_NOTARY_PROFILE)"

network:
	mkdir -p dist
	cd multiplayer && go build -o ../dist/commander-network ./cmd/commander-network

relay:
	mkdir -p dist
	cd multiplayer && go build -o ../dist/commander-relay ./cmd/commander-relay

# The host-mode relay's database: a relocated copy of Homebrew PostgreSQL.
postgres: dist/postgres/bin/postgres

dist/postgres/bin/postgres:
	python3 -I packaging/bundle-postgres.py "$(CURDIR)/dist/postgres" --formula $(PG_FORMULA)

sdk-paths:
	@echo 'export GOWORK="$(SDK_GOWORK)"'

cli:
	mkdir -p dist
ifneq ($(strip $(SDK_RELEASE)),)
	python3 packaging/go-with-sdk.py --release "$(SDK_RELEASE)" build -o dist/agentctl ./cmd/agentctl
else ifeq ($(CONFIG),release)
	python3 packaging/go-with-sdk.py build -o dist/agentctl ./cmd/agentctl
else
	GOWORK="$(SDK_GOWORK)" go build -o dist/agentctl ./cmd/agentctl
endif

test:
	GOWORK="$(SDK_GOWORK)" go test ./...
	cd multiplayer && go test ./...

test-multiplayer-docker:
	python3 multiplayer/deploy/rehearsal/acceptance.py

test-native:
	@set -eu; \
	dev="$${DEVELOPER_DIR:-$$(xcode-select -p)}"; \
	frameworks="$$dev/Library/Developer/Frameworks"; \
	set -- --enable-swift-testing --disable-xctest --jobs "$(NATIVE_TEST_JOBS)"; \
	if [ -d "$$frameworks/Testing.framework" ]; then \
		set -- "$$@" -Xswiftc "-F$$frameworks" \
			-Xswiftc -plugin-path -Xswiftc "$$dev/usr/lib/swift/host/plugins/testing" \
			-Xlinker "-F$$frameworks" -Xlinker -rpath -Xlinker "$$frameworks" \
			-Xlinker -rpath -Xlinker "$$dev/Library/Developer/usr/lib"; \
	fi; \
	exec swift test "$$@"

smoke:
	AGENT_COMMANDER_TEST_INTEGRATION=1 AGENT_COMMANDER_TEST_TMUX=1 go test -count=1 ./cmd/agentctl ./internal/provider

run:
	@if [ ! -x "$(MACOS)/AgentCommander" ] || [ ! -f "$(APP)/Contents/Info.plist" ]; then $(MAKE) app; fi
	open "$(APP)"

# Hot reload: build, quit the running app, relaunch the new build. RELAY=1 also restarts the relay;
# SERVICE=1 also restarts the local agentctl service.
reload:
	MAKE="$(MAKE)" CONFIG="$(CONFIG)" bash packaging/dev-reload.sh reload $(if $(filter 1,$(RELAY)),--relay) $(if $(filter 1,$(SERVICE)),--service)

# Rebuilds and relaunches on every source change until Ctrl-C. Relay and service changes restart them.
dev:
	MAKE="$(MAKE)" CONFIG="$(CONFIG)" bash packaging/dev-reload.sh watch
