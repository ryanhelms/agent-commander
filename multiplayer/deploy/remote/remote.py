#!/usr/bin/env python3
"""Deploy commander-relay host mode to a remote Linux host over SSH and check the connection.

  remote.py deploy docker  USER@HOST --hostname relay.example.org --issuer URL --client-id ID --admin EMAIL
  remote.py deploy docker  USER@HOST --tailnet-login-server https://headscale.example.org \
                           --tailnet-auth-key-file KEY --issuer URL --client-id ID --admin EMAIL
  remote.py deploy systemd USER@HOST --hostname relay.example.org --issuer URL --client-id ID --admin EMAIL
  remote.py status docker|systemd USER@HOST
  remote.py remove docker|systemd USER@HOST
  remote.py connect https://relay.example.org [--pin sha256/...]

Docker mode builds the host image for the remote architecture, streams it over
SSH and runs one container with a named volume. Systemd mode cross-compiles
the relay, installs PostgreSQL from the distribution when it is missing and
runs the relay as a sandboxed system service. Both keep their state across
redeploys and removals.

With --tailnet-login-server, Docker mode also runs a Tailscale sidecar that
joins a Headscale or Tailscale network in userspace mode. The relay listens on
the host's loopback only, and `tailscale serve --tcp` forwards the tailnet port
to it as raw TCP, so TLS and device certificates pass through untouched. Both
containers use the host network: neither depends on the Docker bridge having
egress, and neither creates a TUN device, route or firewall rule on the host.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import shlex
import socket
import ssl
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlparse

THIS = Path(__file__).resolve().parent
MODULE = THIS.parents[1]
IMAGE = "agent-commander-relay"
CONTAINER = "agent-commander-relay"
VOLUME = "agent-commander-relay"
SERVICE_DIR = "/var/lib/agent-commander/relay"
UNIT = "agent-commander-relay.service"
CONTAINER_PORT = 8443
SIDECAR = "agent-commander-relay-tailnet"
SIDECAR_VOLUME = "agent-commander-relay-tailnet"
TAILSCALE_IMAGE = "tailscale/tailscale:stable"
TS_SOCKET = "/var/lib/tailscale/tailscaled.sock"
ARCH = {"x86_64": "amd64", "amd64": "amd64", "aarch64": "arm64", "arm64": "arm64"}


def log(message):
    print(f"==> {message}", file=sys.stderr, flush=True)


class Remote:
    """Runs commands on the target through the system ssh client."""

    def __init__(self, args):
        self.target = args.target
        self.base = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15"]
        if args.ssh_port:
            self.base += ["-p", str(args.ssh_port)]
        if args.identity:
            self.base += ["-i", str(args.identity), "-o", "IdentitiesOnly=yes"]
        for option in args.ssh_option:
            self.base += ["-o", option]
        self.base.append(self.target)
        self._sudo = None

    def run(self, command, stdin=None, capture=False, check=True, data=None):
        result = subprocess.run([*self.base, command], stdin=stdin, input=data, check=False, text=capture,
                                stdout=subprocess.PIPE if capture else sys.stderr)
        if check and result.returncode:
            raise SystemExit(f"remote command failed with status {result.returncode}: {command}")
        return result.stdout.strip() if capture else result.returncode

    def sudo(self):
        """Returns the prefix that runs a command as root on the target."""
        if self._sudo is None:
            uid = self.run("id -u", capture=True)
            self._sudo = "" if uid == "0" else "sudo -n "
        return self._sudo

    def arch(self):
        machine = self.run("uname -sm", capture=True).split()
        if machine[0] != "Linux" or machine[-1] not in ARCH:
            raise SystemExit(f"unsupported target {' '.join(machine)}; expected Linux on x86-64 or arm64")
        return ARCH[machine[-1]]


def docker_prefix(remote):
    """Uses Docker directly when the SSH user may, otherwise through sudo."""
    if remote.run("docker info >/dev/null 2>&1", check=False) == 0:
        return "docker"
    if remote.run(remote.sudo() + "docker info >/dev/null 2>&1", check=False) == 0:
        return remote.sudo() + "docker"
    raise SystemExit("Docker Engine is not available on the target; install it or use the systemd mode")


def init_flags(args):
    flags = ["--name", args.name or args.hostname[0], "--issuer", args.issuer, "--client-id", args.client_id]
    for name in args.hostname:
        flags += ["--hostname", name]
    for email in args.admin:
        flags += ["--admin", email]
    for email in args.allow_email:
        flags += ["--allow-email", email]
    return flags


def public_url(args, status):
    pin = next((line.split(": ", 1)[1] for line in status.splitlines() if line.startswith("Server pin: ")), "")
    if args.public_url:
        return args.public_url, pin
    port = args.port
    host = args.hostname[0]
    if ":" in host:
        host = f"[{host}]"
    return f"https://{host}" + ("" if port == 443 else f":{port}"), pin


def wait_status(fetch, attempts=40):
    status = ""
    for _ in range(attempts):
        status = fetch()
        if "State: running" in status and "Server pin: sha256/" in status:
            return status
        time.sleep(1.5)
    raise SystemExit("the relay did not report a running state:\n" + status)


def deploy_docker(args, remote):
    arch = remote.arch()
    docker = docker_prefix(remote)
    tag = f"{IMAGE}:linux-{arch}"
    log(f"Building {tag}")
    subprocess.run(["docker", "buildx", "build", "--platform", f"linux/{arch}", "--load", "-t", tag,
                    "-f", THIS / "host.Dockerfile", MODULE], check=True)
    log(f"Streaming the image to {remote.target}")
    save = subprocess.Popen(["docker", "save", tag], stdout=subprocess.PIPE)
    gzip = subprocess.Popen(["gzip", "-1"], stdin=save.stdout, stdout=subprocess.PIPE)
    save.stdout.close()
    remote.run(f"gunzip | {docker} load", stdin=gzip.stdout)
    if gzip.wait() or save.wait():
        raise SystemExit("docker save failed")
    remote.run(f"{docker} tag {tag} {IMAGE}:current")
    remote.run(f"{docker} volume create {VOLUME} >/dev/null")
    configured = remote.run(f"{docker} run --rm -v {VOLUME}:/data --entrypoint test {IMAGE}:current -f /data/host.json",
                            check=False) == 0
    remote.run(f"{docker} rm -f {CONTAINER} >/dev/null 2>&1 || true")
    tailnet = None
    if args.tailnet_login_server:
        tailnet = start_sidecar(args, remote, docker)
        args.hostname = [*tailnet["names"], *args.hostname]
        listen = f"127.0.0.1:{args.tailnet_local_port}"
        network = "--network host"
    else:
        listen = f":{CONTAINER_PORT}"
        bind = f"{args.bind}:{args.port}" if args.bind else str(args.port)
        network = f"-p {bind}:{CONTAINER_PORT}"
    if configured and tailnet:
        log("Adding the tailnet names to the existing relay configuration")
        flags = [f"--add-hostname={name}" for name in args.hostname] + [f"--listen={listen}"]
        remote.run(f"{docker} run --rm -v {VOLUME}:/data {IMAGE}:current configure {shlex.join(flags)}")
    elif configured:
        log("Keeping the existing configuration in the relay volume")
    else:
        log("Creating the relay configuration")
        flags = shlex.join(init_flags(args) + ["--listen", listen])
        remote.run(f"{docker} run --rm -v {VOLUME}:/data {IMAGE}:current init {flags}")
    log("Starting the relay container")
    remote.run(f"{docker} run -d --name {CONTAINER} --restart unless-stopped {network} "
               f"-v {VOLUME}:/data --read-only --tmpfs /tmp --cap-drop ALL "
               f"--security-opt no-new-privileges {IMAGE}:current >/dev/null")
    status = wait_status(lambda: docker_status(remote, docker))
    if tailnet:
        log(f"Forwarding tailnet TCP {args.port} to the relay on {listen}")
        remote.run(f"{docker} exec {SIDECAR} tailscale --socket={TS_SOCKET} serve --bg --tcp {args.port} tcp://{listen} >/dev/null")
    return status, tailnet


def tailnet_auth_key(args):
    if args.tailnet_auth_key_file:
        key = Path(args.tailnet_auth_key_file).expanduser().read_text().strip()
    else:
        key = os.environ.get("TS_AUTHKEY", "").strip()
    if any(c.isspace() for c in key):
        raise SystemExit("the tailnet auth key must be a single token")
    return key


def tailnet_state(remote, docker):
    """The sidecar's `tailscale status --json`, or None while tailscaled is not answering."""
    text = remote.run(f"{docker} exec {SIDECAR} tailscale --socket={TS_SOCKET} status --json 2>/dev/null", capture=True, check=False)
    try:
        return json.loads(text)
    except ValueError:
        return None


def start_sidecar(args, remote, docker):
    """Starts tailscaled in its own container, logs it in once and returns its tailnet names."""
    login = urlparse(args.tailnet_login_server)
    if login.scheme not in ("https", "http") or not login.hostname or login.username or login.query or login.fragment:
        raise SystemExit("--tailnet-login-server must be a plain https:// URL")
    image = args.tailnet_image
    if remote.run(f"{docker} image inspect {shlex.quote(image)} >/dev/null 2>&1", check=False):
        log(f"Pulling {image} on the target")
        remote.run(f"{docker} pull -q {shlex.quote(image)} >/dev/null")
    log("Starting the tailnet sidecar")
    remote.run(f"{docker} rm -f {SIDECAR} >/dev/null 2>&1 || true")
    remote.run(f"{docker} volume create {SIDECAR_VOLUME} >/dev/null")
    # tailscaled keeps its node key, preferences and serve configuration in the
    # volume, so a restart or redeploy rejoins as the same node without an auth
    # key. Userspace networking needs no TUN device or capabilities, and port 0
    # avoids a host tailscaled's UDP port.
    remote.run(f"{docker} run -d --name {SIDECAR} --network host --restart unless-stopped --cap-drop ALL "
               f"--security-opt no-new-privileges -v {SIDECAR_VOLUME}:/var/lib/tailscale "
               f"--entrypoint tailscaled {shlex.quote(image)} --tun=userspace-networking --port=0 "
               f"--state=/var/lib/tailscale/tailscaled.state --statedir=/var/lib/tailscale "
               f"--socket={TS_SOCKET} >/dev/null")
    state = None
    # Right after start tailscaled reports NoState until it has read its saved login.
    for _ in range(60):
        state = tailnet_state(remote, docker)
        if state and state.get("BackendState") not in ("", "NoState"):
            break
        time.sleep(0.5)
    if not state:
        raise SystemExit("tailscaled did not start in the sidecar:\n" +
                         remote.run(f"{docker} logs --tail 20 {SIDECAR} 2>&1", capture=True, check=False))
    up = ["tailscale", f"--socket={TS_SOCKET}", "up", "--reset", f"--login-server={args.tailnet_login_server}",
          f"--hostname={args.tailnet_hostname}", "--accept-dns=false", "--timeout=90s"]
    if args.tailnet_tag:
        up.append("--advertise-tags=" + ",".join(args.tailnet_tag))
    key = ""
    if state.get("BackendState") in ("NeedsLogin", "NoState"):
        key = tailnet_auth_key(args)
        if not key:
            raise SystemExit("the sidecar is not logged in yet; pass --tailnet-auth-key-file or set TS_AUTHKEY")
        # The key travels on standard input and never appears in a command line or the container's config.
        up.append("--auth-key=file:/dev/stdin")
        log(f"Joining {args.tailnet_login_server} as {args.tailnet_hostname}")
    else:
        log(f"Keeping the sidecar's tailnet login on {state.get('CurrentTailnet', {}).get('Name', 'the tailnet')}")
    remote.run(f"{docker} exec -i {SIDECAR} {shlex.join(up)}", data=key.encode() if key else b"")
    for _ in range(60):
        state = tailnet_state(remote, docker) or {}
        me = state.get("Self") or {}
        if state.get("BackendState") == "Running" and me.get("TailscaleIPs"):
            break
        time.sleep(1)
    else:
        raise SystemExit(f"the sidecar did not reach the tailnet: {state.get('BackendState')}")
    dns = (me.get("DNSName") or "").rstrip(".")
    names = ([dns] if dns else []) + list(me["TailscaleIPs"])
    log(f"The relay node is {dns or me.get('HostName')} ({', '.join(me['TailscaleIPs'])})")
    return {"tailnet": (state.get("CurrentTailnet") or {}).get("Name", ""), "dns": dns,
            "addresses": me["TailscaleIPs"], "tags": me.get("Tags") or [], "names": names}


def docker_status(remote, docker):
    return remote.run(f"{docker} exec {CONTAINER} commander-relay host --dir /data status 2>&1", capture=True, check=False)


def build_binary(arch, out):
    log(f"Building commander-relay for linux/{arch}")
    env = dict(os.environ, CGO_ENABLED="0", GOOS="linux", GOARCH=arch, GOWORK="off")
    subprocess.run(["go", "build", "-trimpath", "-buildvcs=false", "-o", out, "./cmd/commander-relay"],
                   cwd=MODULE, env=env, check=True)


def deploy_systemd(args, remote):
    arch = remote.arch()
    sudo = remote.sudo()
    with tempfile.TemporaryDirectory() as tmp:
        binary = Path(tmp) / "commander-relay"
        build_binary(arch, binary)
        log(f"Copying the relay to {remote.target}")
        staged = remote.run("mktemp /tmp/commander-relay.XXXXXX", capture=True)
        with open(binary, "rb") as source:
            remote.run(f"cat > {shlex.quote(staged)}", stdin=source)
    listen = f"{args.bind}:{args.port}" if args.bind else f":{args.port}"
    flags = shlex.join([staged, *init_flags(args), "--listen", listen])
    log("Installing PostgreSQL when needed and the systemd service")
    with open(THIS / "systemd-install.sh", "rb") as script:
        remote.run(f"{sudo}sh -s -- {flags}", stdin=script)
    return wait_status(lambda: systemd_status(remote))


def systemd_status(remote):
    sudo = remote.sudo()
    return remote.run(f"{sudo}systemctl is-active {UNIT} >/dev/null && "
                      f"{sudo}/usr/local/bin/commander-relay host --dir {SERVICE_DIR} status 2>&1", capture=True, check=False)


def deploy(args):
    if args.tailnet_login_server and args.mode != "docker":
        raise SystemExit("--tailnet-login-server needs Docker mode")
    if not args.hostname and not args.tailnet_login_server:
        raise SystemExit("--hostname is required without a tailnet")
    remote = Remote(args)
    tailnet = None
    if args.mode == "docker":
        status, tailnet = deploy_docker(args, remote)
    else:
        status = deploy_systemd(args, remote)
    url, pin = public_url(args, status)
    report = {"mode": args.mode, "url": url, "pin": pin}
    if tailnet:
        report["tailnet"] = {k: tailnet[k] for k in ("tailnet", "dns", "addresses", "tags")}
    print(json.dumps(report, indent=2))
    if not args.no_connect:
        report = connect(url, pin, args.connect_address)
        print(json.dumps(report, indent=2))


def status(args):
    remote = Remote(args)
    if args.mode == "docker":
        docker = docker_prefix(remote)
        print(docker_status(remote, docker))
        if remote.run(f"{docker} inspect {SIDECAR} >/dev/null 2>&1", check=False) == 0:
            state = tailnet_state(remote, docker) or {}
            me = state.get("Self") or {}
            print(f"Tailnet: {(state.get('CurrentTailnet') or {}).get('Name', '')} {state.get('BackendState', 'not answering')}")
            print(f"Tailnet node: {(me.get('DNSName') or '').rstrip('.')} {' '.join(me.get('TailscaleIPs') or [])}")
    else:
        print(systemd_status(remote) or f"{UNIT} is not active")


def remove(args):
    remote = Remote(args)
    if args.mode == "docker":
        docker = docker_prefix(remote)
        remote.run(f"{docker} rm -f {CONTAINER} >/dev/null 2>&1 || true")
        print(f"Removed the {CONTAINER} container. The {VOLUME} volume keeps the relay's data and TLS identity.")
        if remote.run(f"{docker} inspect {SIDECAR} >/dev/null 2>&1", check=False) == 0:
            remote.run(f"{docker} rm -f {SIDECAR} >/dev/null")
            print(f"Removed the {SIDECAR} sidecar. The {SIDECAR_VOLUME} volume keeps the tailnet node's login.")
    else:
        remote.run(f"{remote.sudo()}/usr/local/bin/commander-relay host uninstall")
        print(f"Removed {UNIT}. {SERVICE_DIR} keeps the relay's data and TLS identity.")


# --- Connection check -------------------------------------------------------

def openssl(*args, data=None):
    return subprocess.run(["openssl", *map(str, args)], input=data, check=True, stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL).stdout


def spki_pin(der):
    public = openssl("x509", "-inform", "DER", "-pubkey", "-noout", data=der)
    spki = openssl("pkey", "-pubin", "-outform", "DER", data=public)
    return "sha256/" + base64.b64encode(hashlib.sha256(spki).digest()).decode()


def device_certificate(directory):
    """A self-signed P-256 client certificate, as Agent Commander devices present."""
    key, cert = directory / "device.key", directory / "device.pem"
    openssl("req", "-x509", "-sha256", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256",
            "-pkeyopt", "ec_param_enc:named_curve", "-nodes", "-days", "1", "-subj", "/CN=Commander device",
            "-addext", "basicConstraints=critical,CA:FALSE", "-addext", "extendedKeyUsage=clientAuth",
            "-addext", "keyUsage=critical,digitalSignature", "-keyout", key, "-out", cert)
    return cert, key


def request(host, port, server_name, path, pin, client=None, address=None):
    """Sends one HTTP/1.1 GET over TLS 1.3 after checking the server's SPKI pin."""
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    ctx.minimum_version = ssl.TLSVersion.TLSv1_3
    if client:
        ctx.load_cert_chain(*client)
    with socket.create_connection((address or host, port), 10) as raw, \
            ctx.wrap_socket(raw, server_hostname=server_name) as conn:
        seen = spki_pin(conn.getpeercert(binary_form=True))
        if pin and seen != pin:
            raise SystemExit(f"server pin mismatch: expected {pin}, received {seen}")
        conn.sendall(f"GET {path} HTTP/1.1\r\nHost: {server_name}\r\nConnection: close\r\n\r\n".encode())
        response = b""
        while chunk := conn.recv(65536):
            response += chunk
        version = conn.version()
    head, _, body = response.partition(b"\r\n\r\n")
    if b"\r\ntransfer-encoding: chunked" in head.lower():
        decoded = b""
        while body:
            size, _, rest = body.partition(b"\r\n")
            length = int(size.split(b";")[0], 16)
            if length == 0:
                break
            decoded, body = decoded + rest[:length], rest[length + 2:]
        body = decoded
    return version, seen, int(head.split(b" ", 2)[1]), body


def connect(url, pin="", address=None):
    """Checks what Agent Commander checks when it adds a server, then device-authenticated readiness."""
    parsed = urlparse(url)
    if parsed.scheme != "https" or not parsed.hostname:
        raise SystemExit("expected an https:// relay URL")
    host, port = parsed.hostname, parsed.port or 443
    deadline = time.monotonic() + 60
    while True:
        try:
            version, seen, code, body = request(host, port, host, "/v1/info", pin, address=address)
            break
        except (OSError, ssl.SSLError, IndexError, ValueError):
            if time.monotonic() > deadline:
                raise
            time.sleep(1)
    if code != 200:
        raise SystemExit(f"/v1/info returned HTTP {code}")
    info = json.loads(body)
    with tempfile.TemporaryDirectory() as tmp:
        client = device_certificate(Path(tmp))
        _, _, ready, _ = request(host, port, host, "/ready", seen, client=client, address=address)
        try:
            _, _, anonymous, _ = request(host, port, host, "/ready", seen, address=address)
        except (OSError, ssl.SSLError):
            anonymous = 0
    if ready != 204:
        raise SystemExit(f"device-authenticated /ready returned HTTP {ready}")
    if anonymous == 204:
        raise SystemExit("/ready answered a client without a device certificate")
    return {"url": url, "tls": version, "pin": seen, "relay": f"{info.get('mode')} {info.get('version')}",
            "name": info.get("name"), "issuer": info.get("issuer"), "device_ready": ready,
            "anonymous_ready": anonymous or "refused"}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)

    def target(sub):
        sub.add_argument("mode", choices=["docker", "systemd"])
        sub.add_argument("target", help="SSH destination, such as ops@relay.example.org")
        sub.add_argument("--ssh-port", type=int)
        sub.add_argument("-i", "--identity", type=Path, help="SSH private key")
        sub.add_argument("-o", "--ssh-option", action="append", default=[], help="extra ssh -o option; repeatable")

    d = commands.add_parser("deploy", help="install or upgrade the relay on the target")
    target(d)
    d.add_argument("--hostname", action="append", default=[],
                   help="DNS name or IP address clients use; the first one forms the URL; repeatable; "
                        "optional with a tailnet, which adds the node's MagicDNS name and addresses")
    d.add_argument("--issuer", required=True, help="HTTPS OIDC issuer, such as https://accounts.google.com")
    d.add_argument("--client-id", required=True, help="OIDC client ID of the Agent Commander desktop app")
    d.add_argument("--admin", action="append", required=True, help="administrator email; repeatable")
    d.add_argument("--allow-email", action="append", default=[], help="allowed member email; repeatable")
    d.add_argument("--name", help="display name; defaults to the first hostname")
    d.add_argument("--port", type=int, default=443, help="public TCP port (default 443)")
    d.add_argument("--bind", default="", help="bind address on the target (default all interfaces)")
    d.add_argument("--no-connect", action="store_true", help="skip the connection check")
    d.add_argument("--public-url", help="URL clients use when a proxy or port mapping changes the address")
    d.add_argument("--connect-address", help="address to dial for the check when DNS does not reach the target")
    t = d.add_argument_group("tailnet (Docker mode)")
    t.add_argument("--tailnet-login-server", help="Headscale or Tailscale control URL, such as https://headscale.example.org")
    t.add_argument("--tailnet-auth-key-file", help="file holding a pre-auth key for the first join; "
                                                   "TS_AUTHKEY is used when this is not given")
    t.add_argument("--tailnet-hostname", default="agent-relay", help="tailnet node name (default agent-relay)")
    t.add_argument("--tailnet-tag", action="append", default=[], help="tag to advertise, such as tag:relay; repeatable")
    t.add_argument("--tailnet-local-port", type=int, default=18443,
                   help="loopback port the relay listens on behind tailscale serve (default 18443)")
    t.add_argument("--tailnet-image", default=TAILSCALE_IMAGE, help=f"sidecar image (default {TAILSCALE_IMAGE})")
    d.set_defaults(func=deploy)

    s = commands.add_parser("status", help="show the deployed relay's state and pins")
    target(s)
    s.set_defaults(func=status)
    r = commands.add_parser("remove", help="stop and remove the relay, keeping its data")
    target(r)
    r.set_defaults(func=remove)

    c = commands.add_parser("connect", help="check a relay as Agent Commander would")
    c.add_argument("url")
    c.add_argument("--pin", default="", help="expected server pin from the deploy or status output")
    c.add_argument("--address", help="address to dial instead of resolving the URL's host")
    c.set_defaults(func=lambda a: print(json.dumps(connect(a.url, a.pin, a.address), indent=2)))

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
