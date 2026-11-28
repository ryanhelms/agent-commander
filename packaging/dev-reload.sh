#!/usr/bin/env bash
# Hot reload for the native app, like a web dev server.
#
#   packaging/dev-reload.sh reload [--relay] [--service]   build, quit, relaunch once
#   packaging/dev-reload.sh watch              reload on every source change until Ctrl-C
#
# `make reload` and `make dev` call this. The script builds before it quits the app, so a compile
# error leaves the running copy alone and says so. Changes under multiplayer/ also restart the
# host-mode relay when its LaunchAgent is installed. Changes to the Go service (cmd/, internal/,
# harness/, go.mod) also restart `agentctl serve`, which otherwise outlives the app. Every run's output is appended to
# dist/dev-reload.log.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

MAKE="${MAKE:-make}"
CONFIG="${CONFIG:-debug}"
APP="$ROOT/dist/Agent Commander.app"
BUNDLE_ID="local.agentcommander.cockpit"
EXECUTABLE="$APP/Contents/MacOS/AgentCommander"
RELAY_LABEL="local.agentcommander.relay"
LOG="$ROOT/dist/dev-reload.log"
NETWORK_RELOAD="$ROOT/dist/dev-reload-network"
DEBOUNCE="${DEV_RELOAD_DEBOUNCE:-1}"

mkdir -p "$ROOT/dist"

say() { printf '\033[1m[dev]\033[0m %s\n' "$*"; }

notify() {
    # A banner, so a result is seen even when the terminal is hidden. Best effort.
    osascript -e "display notification \"$2\" with title \"Agent Commander dev\" subtitle \"$1\"" >/dev/null 2>&1 || true
}

running_pids() {
    pgrep -x AgentCommander 2>/dev/null || true
}

quit_app() {
    [ -n "$(running_pids)" ] || return 0
    say "Quitting Agent Commander"
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    for _ in $(seq 1 50); do
        [ -n "$(running_pids)" ] || return 0
        sleep 0.2
    done
    say "Still running after 10 s; sending SIGTERM"
    pkill -TERM -x AgentCommander 2>/dev/null || true
    for _ in $(seq 1 25); do
        [ -n "$(running_pids)" ] || return 0
        sleep 0.2
    done
    say "Agent Commander did not quit"
    return 1
}

restart_relay() {
    local domain="gui/$(id -u)"
    if launchctl print "$domain/$RELAY_LABEL" >/dev/null 2>&1; then
        say "Restarting the host-mode relay ($RELAY_LABEL)"
        launchctl kickstart -k "$domain/$RELAY_LABEL"
        local program
        program="$(launchctl print "$domain/$RELAY_LABEL" 2>/dev/null | awk '/^[[:space:]]*program = /{sub(/^[[:space:]]*program = /, ""); print; exit}')"
        if [ -n "$program" ] && [ "$program" != "$APP/Contents/MacOS/commander-relay" ]; then
            say "Note: the relay runs $program, not this checkout's build."
            say "Run '$APP/Contents/MacOS/commander-relay host install' to point it here."
        fi
    else
        say "No host-mode relay installed; skipping the relay restart"
    fi
}

# Builds everything the bundle needs without touching the bundle, so the app can keep running.
prebuild() {
    "$MAKE" cli network relay postgres CONFIG="$CONFIG" || return
    go build -o "$NETWORK_RELOAD" ./packaging/devreloadnetwork || return
    swift build -c "$CONFIG" --product AgentCommander
}

reload() {
    local relay="${1:-0}" service="${2:-0}"
    local service_failed=0
    local -a launch_app=(open)
    local started
    started="$(date +%s)"
    {
        echo
        echo "=== reload $(date '+%Y-%m-%d %H:%M:%S') relay=$relay service=$service"
    } >>"$LOG"

    say "Building"
    if ! prebuild 2>&1 | tee -a "$LOG"; then
        say "Build failed. The app you have open is the previous build. Details: $LOG"
        notify "Build failed" "Still running the previous build. See dist/dev-reload.log."
        return 1
    fi

    quit_app || return
    if ! "$NETWORK_RELOAD" stop 2>&1 | tee -a "$LOG"; then
        say "The old network helper could not be stopped safely. Agent Commander was quit. Details: $LOG"
        notify "Network helper stop failed" "Inspect the normal owner socket before retrying. See dist/dev-reload.log."
        return 1
    fi

    # Incremental: the compiled products are fresh, so this copies them into the bundle and signs it.
    if ! "$MAKE" app CONFIG="$CONFIG" 2>&1 | tee -a "$LOG"; then
        say "Bundling failed. Agent Commander is not running. Details: $LOG"
        notify "Bundling failed" "Agent Commander was quit and not reopened. See dist/dev-reload.log."
        return 1
    fi

    if [ "$service" = 1 ]; then
        # Launch Services does not pass through the shell's service overrides.
        # Give the replacement app and agentctl the same local endpoint.
        local service_home="${AGENT_COMMANDER_HOME:-}" service_socket="${AGENT_COMMANDER_SOCKET:-${AC_SOCKET:-}}"
        if [ -n "$service_home" ]; then
            [[ "$service_home" = /* ]] || service_home="$ROOT/$service_home"
            export AGENT_COMMANDER_HOME="$service_home"
            launch_app+=(--env "AGENT_COMMANDER_HOME=$service_home")
        fi
        if [ -n "$service_socket" ]; then
            [[ "$service_socket" = /* ]] || service_socket="$ROOT/$service_socket"
            export AGENT_COMMANDER_SOCKET="$service_socket"
            launch_app+=(--env "AGENT_COMMANDER_SOCKET=$service_socket")
        fi
        if ! "$NETWORK_RELOAD" service-stop 2>&1 | tee -a "$LOG"; then
            say "The old Commander service could not be stopped safely. Details: $LOG"
            notify "Service stop failed" "The app will reopen. Inspect the service socket before retrying."
            service_failed=1
        fi
    fi

    if [ "$relay" = 1 ]; then restart_relay 2>&1 | tee -a "$LOG" || say "The relay restart failed. Details: $LOG"; fi

    say "Opening $APP"
    if ! "${launch_app[@]}" "$APP" 2>&1 | tee -a "$LOG"; then
        say "Launch Services could not open the app. Details: $LOG"
        notify "Launch failed" "The new build did not start. See dist/dev-reload.log."
        return 1
    fi
    for _ in $(seq 1 50); do
        if pgrep -f "$EXECUTABLE" >/dev/null 2>&1; then
            if ! "$NETWORK_RELOAD" ready "$APP/Contents/MacOS/commander-network" 2>&1 | tee -a "$LOG"; then
                say "The app opened but network helper replacement could not be verified. Details: $LOG"
                notify "Network helper launch failed" "The app opened. Inspect the network helper in dist/dev-reload.log."
                return 1
            fi
            if [ "$service" = 1 ]; then
                if [ "$service_failed" = 1 ]; then
                    say "The app opened without a verified service replacement. Details: $LOG"
                    return 1
                fi
                if ! "$NETWORK_RELOAD" service-ready "$APP/Contents/MacOS/agentctl" 2>&1 | tee -a "$LOG"; then
                    say "The app opened but Commander service replacement could not be verified. Details: $LOG"
                    notify "Service launch failed" "The app opened. Inspect the Commander service in dist/dev-reload.log."
                    return 1
                fi
            fi
            local took=$(( $(date +%s) - started ))
            say "Reloaded in ${took}s"
            echo "=== reloaded in ${took}s" >>"$LOG"
            notify "Reloaded" "The new build is running (${took}s)."
            return 0
        fi
        sleep 0.2
    done
    say "The app did not start. Details: $LOG"
    notify "Launch failed" "The new build did not start. See dist/dev-reload.log."
    return 1
}

# Source files that change the bundle. Tests and docs don't trigger a reload.
WATCH_PATHS=(Sources Package.swift Package.resolved cmd internal harness multiplayer packaging/Info.plist go.mod go.sum)

changed_since() {
    local stamp="$1"
    find "${WATCH_PATHS[@]}" -type f -newer "$stamp" \
        ! -name '*_test.go' ! -name '.*' ! -path 'multiplayer/deploy/*' \
        \( -path 'Sources/*' -o -name '*.go' -o -name 'go.mod' -o -name 'go.sum' \
           -o -name 'Package.swift' -o -name 'Package.resolved' -o -name 'Info.plist' \) \
        2>/dev/null || true
}

wait_for_change() {
    if command -v fswatch >/dev/null 2>&1; then
        # Blocks until one batch of events arrives.
        fswatch -1 -r -l 0.5 "${WATCH_PATHS[@]}" >/dev/null 2>&1 || sleep 1
    else
        sleep 1
    fi
}

watch() {
    local stamp="$ROOT/dist/.dev-reload-stamp"
    touch "$stamp"
    if command -v fswatch >/dev/null 2>&1; then
        say "Watching for changes with fswatch. Ctrl-C to stop."
    else
        say "Watching for changes by polling every second (brew install fswatch for instant events). Ctrl-C to stop."
    fi
    say "Starting with a fresh build"
    reload 1 1 || true
    while true; do
        # Changes made during the last build count too, so look before waiting for an event.
        if [ -z "$(changed_since "$stamp")" ]; then
            wait_for_change
            continue
        fi
        # Let an editor or an agent finish writing a batch of files.
        sleep "$DEBOUNCE"
        local changed next="$stamp.next"
        touch "$next"
        changed="$(changed_since "$stamp")"
        mv "$next" "$stamp"
        [ -n "$changed" ] || continue
        say "Changed:"
        printf '%s\n' "$changed" | head -10 | sed 's/^/  /'
        local relay=0
        local service=0
        if printf '%s\n' "$changed" | grep -q '^multiplayer/'; then relay=1; fi
        if printf '%s\n' "$changed" | grep -Eq '^(cmd|internal|harness)/|^go\.(mod|sum)$'; then service=1; fi
        reload "$relay" "$service" || true
    done
}

case "${1:-}" in
    reload)
        relay=0 service=0
        for arg in "${@:2}"; do
            case "$arg" in
                --relay) relay=1 ;;
                --service) service=1 ;;
                *) echo "unknown option: $arg" >&2; exit 2 ;;
            esac
        done
        [ "${RELAY:-0}" = 1 ] && relay=1
        [ "${SERVICE:-0}" = 1 ] && service=1
        reload "$relay" "$service"
        ;;
    watch)
        watch
        ;;
    *)
        echo "usage: $0 reload [--relay] [--service] | watch" >&2
        exit 2
        ;;
esac
