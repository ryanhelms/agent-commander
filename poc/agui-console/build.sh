#!/bin/sh
set -eu

cd "$(dirname "$0")"
proof_dir="$(pwd)"
app='dist/Agent Commander Console.app'
npm run build
mkdir -p "$app/Contents/MacOS"
(
    cd ../..
    go build -o "$proof_dir/dist/agentctl" ./cmd/agentctl
)
swiftc -parse-as-library -module-cache-path "${AGUI_SWIFT_CACHE:-$proof_dir/dist/swift-module-cache}" \
    native/main.swift -framework WebKit -o "$app/Contents/MacOS/AgentCommanderConsole"
cp native/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
