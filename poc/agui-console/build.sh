#!/bin/sh
set -eu

sdk_release=
if [ -n "${SDK_RELEASE:-}" ]; then
    sdk_release="$(cd "$SDK_RELEASE" && pwd)"
fi
cd "$(dirname "$0")"
proof_dir="$(pwd)"
app='dist/Agent Commander Console.app'
npm run build
mkdir -p "$app/Contents/MacOS"
(
    cd ../..
    if [ -n "$sdk_release" ]; then
        python3 packaging/go-with-sdk.py --release "$sdk_release" build -o "$proof_dir/dist/agentctl" ./cmd/agentctl
    elif [ "${CONFIG:-debug}" = release ]; then
        python3 packaging/go-with-sdk.py build -o "$proof_dir/dist/agentctl" ./cmd/agentctl
    else
        go build -o "$proof_dir/dist/agentctl" ./cmd/agentctl
    fi
)
swiftc -parse-as-library -module-cache-path "${AGUI_SWIFT_CACHE:-$proof_dir/dist/swift-module-cache}" \
    native/main.swift -framework WebKit -o "$app/Contents/MacOS/AgentCommanderConsole"
cp native/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
