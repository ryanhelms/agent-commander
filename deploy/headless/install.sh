#!/bin/sh
# Install or upgrade the headless Agent Commander service on this Linux server.
#
#   gh release download -R ryanhelms/agent-commander -p install.sh -O - | sh
#   gh release download v0.2.0 -R ryanhelms/agent-commander -p install.sh -O - | sh -s -- v0.2.0
#   curl -fsSL https://github.com/OWNER/REPO/releases/latest/download/install.sh | sh
#
# Usage: install.sh [VERSION] [INSTALL_FLAGS...]
#   VERSION        a release tag, or "latest" (the default): the newest
#                  release that is not a draft, prereleases included.
#   INSTALL_FLAGS  passed to `agentctl host install`, such as --sudo-linger.
#
# It downloads with `gh` when gh is signed in, and otherwise anonymously over
# HTTPS, which works once the repository is public. It verifies the archive
# against the release's SHA256SUMS, then hands over to `agentctl host install`.
#
# Settings: AGENT_COMMANDER_REPO (owner/name), AGENT_COMMANDER_VERSION, and
# AGENT_COMMANDER_DOWNLOAD_BASE to download from a mirror instead of GitHub.
set -eu

repo=${AGENT_COMMANDER_REPO:-ryanhelms/agent-commander}
version=${AGENT_COMMANDER_VERSION:-latest}
if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then
	version=$1
	shift
fi

say() { printf 'agent-commander: %s\n' "$*" >&2; }
die() { say "$*"; exit 1; }

[ "$(uname -s)" = Linux ] || die "the headless service runs on Linux; this is $(uname -s)"
case $(uname -m) in
x86_64 | amd64) arch=amd64 ;;
aarch64 | arm64) arch=arm64 ;;
*) die "unsupported architecture $(uname -m)" ;;
esac
asset=agent-commander-headless-linux-$arch.tar.gz

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

fetch() { # URL FILE
	if command -v curl >/dev/null 2>&1; then
		if [ -n "${AGENT_COMMANDER_DOWNLOAD_BASE:-}" ]; then
			curl -fsSL -o "$2" "$1"
		else
			curl -fsSL --proto '=https' --tlsv1.2 -o "$2" "$1"
		fi
	elif command -v wget >/dev/null 2>&1; then
		wget -q -O "$2" "$1"
	else
		die "install curl, wget or gh to download the release"
	fi
}

use_gh=no
if [ -z "${AGENT_COMMANDER_DOWNLOAD_BASE:-}" ] && command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
	use_gh=yes
fi

if [ "$version" = latest ]; then
	if [ $use_gh = yes ]; then
		version=$(gh release list -R "$repo" --exclude-drafts --limit 1 --json tagName --jq '.[0].tagName')
	elif [ -n "${AGENT_COMMANDER_DOWNLOAD_BASE:-}" ]; then
		fetch "$AGENT_COMMANDER_DOWNLOAD_BASE/LATEST" "$tmp/latest"
		version=$(tr -d ' \n' <"$tmp/latest")
	else
		fetch "https://api.github.com/repos/$repo/releases?per_page=1" "$tmp/releases.json"
		version=$(sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$tmp/releases.json" | head -n 1)
	fi
	[ -n "$version" ] || die "no release found in $repo; check that gh is signed in with access to it"
fi
case $version in
*[!A-Za-z0-9._+-]* | "") die "invalid version $version" ;;
esac

say "downloading $version for linux-$arch"
if [ $use_gh = yes ]; then
	gh release download "$version" -R "$repo" -p "$asset" -p SHA256SUMS -D "$tmp"
else
	base=${AGENT_COMMANDER_DOWNLOAD_BASE:-https://github.com/$repo/releases/download}
	fetch "$base/$version/$asset" "$tmp/$asset"
	fetch "$base/$version/SHA256SUMS" "$tmp/SHA256SUMS"
fi

expected=$(awk -v f="$asset" '$2 == f || $2 == "*" f { print $1 }' "$tmp/SHA256SUMS")
[ -n "$expected" ] || die "SHA256SUMS does not list $asset"
if command -v sha256sum >/dev/null 2>&1; then
	actual=$(sha256sum "$tmp/$asset" | awk '{ print $1 }')
else
	actual=$(shasum -a 256 "$tmp/$asset" | awk '{ print $1 }')
fi
[ "$actual" = "$expected" ] || die "checksum mismatch for $asset"
say "verified $asset against SHA256SUMS"

mkdir "$tmp/unpack"
tar -xzf "$tmp/$asset" -C "$tmp/unpack"
new="$tmp/unpack/agent-commander-headless/agentctl"
[ -x "$new" ] || die "the archive has no agentctl"

# The installed version, when there is one, installs the new binary. It then
# rolls back even if the new binary cannot start at all.
data=${XDG_DATA_HOME:-$HOME/.local/share}/agent-commander
installer=$new
if [ -x "$data/current/agentctl" ]; then
	installer=$data/current/agentctl
fi
"$new" host doctor >"$tmp/doctor.json" 2>&1 || say "some prerequisites are missing; run: agentctl host doctor"
"$installer" host install --source "$new" --version "$version" "$@"
