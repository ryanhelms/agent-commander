#!/bin/sh
# Stamps the git version into a built bundle's Info.plist.
# CFBundleShortVersionString: the latest tag's x.y.z. CFBundleVersion: the commit count.
# AgentCommanderGitVersion: `git describe --tags --dirty`, shown in the main window's footer.
set -eu
plist="$1"
describe=$(git describe --tags --dirty --always 2>/dev/null || echo unknown)
short=$(printf '%s' "$describe" | sed -n 's/^v\{0,1\}\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')
build=$(git rev-list --count HEAD 2>/dev/null || echo 1)
pb=/usr/libexec/PlistBuddy
[ -n "$short" ] && "$pb" -c "Set :CFBundleShortVersionString $short" "$plist"
"$pb" -c "Set :CFBundleVersion $build" "$plist"
"$pb" -c "Delete :AgentCommanderGitVersion" "$plist" 2>/dev/null || true
"$pb" -c "Add :AgentCommanderGitVersion string $describe" "$plist"
