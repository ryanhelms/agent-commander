#!/bin/sh
# Install commander-relay host mode as a systemd service. Run as root on the
# target host: systemd-install.sh BINARY [host init flags...]
# An existing host.json is kept, so a redeploy only replaces the executable.
set -eu

binary=$1
shift
account=agent-commander
base=/var/lib/agent-commander
dir=$base/relay

command -v systemctl >/dev/null 2>&1 || { echo "systemd is required for the service deployment" >&2; exit 1; }

have_postgres() {
	for bin in /usr/lib/postgresql/*/bin /usr/pgsql-*/bin; do
		[ -x "$bin/initdb" ] && [ -x "$bin/postgres" ] && return 0
	done
	command -v initdb >/dev/null 2>&1 && command -v postgres >/dev/null 2>&1
}

if ! have_postgres; then
	if command -v apt-get >/dev/null 2>&1; then
		# Host mode runs its own private cluster, so skip the distribution's default one.
		install -d -m 0755 /etc/postgresql-common/createcluster.d
		echo 'create_main_cluster = false' >/etc/postgresql-common/createcluster.d/agent-commander.conf
		export DEBIAN_FRONTEND=noninteractive
		apt-get update -qq
		apt-get install -y -qq --no-install-recommends postgresql >/dev/null
	elif command -v dnf >/dev/null 2>&1; then
		dnf install -y -q postgresql-server
	else
		echo "install PostgreSQL 15 or newer, then deploy again" >&2
		exit 1
	fi
fi

if ! id -u "$account" >/dev/null 2>&1; then
	nologin=$(command -v nologin || echo /bin/false)
	useradd --system --user-group --home-dir "$base" --no-create-home --shell "$nologin" "$account"
fi
install -d -o root -g root -m 0755 "$base"
install -d -o "$account" -g "$account" -m 0700 "$dir"
install -m 0755 "$binary" /usr/local/bin/commander-relay.new
mv -f /usr/local/bin/commander-relay.new /usr/local/bin/commander-relay
rm -f "$binary"

if [ ! -f "$dir/host.json" ]; then
	setpriv --reuid="$account" --regid="$account" --init-groups \
		env HOME="$base" /usr/local/bin/commander-relay host --dir "$dir" init "$@"
else
	echo "Keeping the existing configuration in $dir/host.json"
fi
/usr/local/bin/commander-relay host --dir "$dir" install
