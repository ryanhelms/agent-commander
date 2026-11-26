#!/usr/bin/env python3
"""Deploy the relay to two disposable Linux hosts over SSH and connect to each.

One host runs systemd and receives the service deployment. The other runs
Docker Engine and receives the container deployment. Both are local Docker
containers reached only through SSH, as a remote server would be. For each
host the rehearsal deploys, checks the connection, adds the relay to a real
Agent Commander device agent with isolated state, restarts the relay,
redeploys and confirms that the TLS identity survives, then removes it.

The tailnet mode starts a disposable Headscale on a private Docker network,
deploys the relay to a Docker host behind a userspace Tailscale sidecar
with no published port, and checks it from a second tailnet node: the connection
check, and the Linux device agent's tailnet-status, tailnet-relays and
server-probe verbs. It never contacts a real tailnet's control server.

  python3 -B multiplayer/deploy/remote/testhosts/rehearse.py [--keep] [--mode docker|systemd|tailnet]
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import time

THIS = Path(__file__).resolve().parent
REMOTE = THIS.parent / "remote.py"
MODULE = THIS.parents[2]
ISSUER = "https://accounts.google.com"
CLIENT_ID = "rehearsal.apps.googleusercontent.com"
HOSTS = {
    # mode: (image, container, ssh port, relay port)
    "systemd": ("acr-testhost-systemd", "acr-rehearsal-systemd", 22401, 22443),
    "docker": ("acr-testhost-docker", "acr-rehearsal-docker", 22402, 22444),
    "tailnet": ("acr-testhost-docker", "acr-rehearsal-tailnet", 22403, 22445),
}
# The private network for the tailnet rehearsal. headscale/config.yaml names
# the control server's address on it.
TAILNET_NET, TAILNET_SUBNET = "acr-rehearsal-tailnet", "10.247.0.0/24"
HEADSCALE, HEADSCALE_IP, HEADSCALE_IMAGE = "acr-rehearsal-headscale", "10.247.0.10", "headscale/headscale:0.27.1"
LOGIN_SERVER = f"http://{HEADSCALE_IP}:8080"
TS_HOST, CLIENT, CLIENT_IMAGE = "acr-rehearsal-tailnet", "acr-rehearsal-client", "acr-testhost-client"
RELAY_NODE = "agent-relay"
RELAY_URL = f"https://{RELAY_NODE}.tail.internal"


def log(message):
    print(f"\n### {message}", flush=True)


def run(args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def output(args, **kwargs):
    return run(args, stdout=subprocess.PIPE, text=True, **kwargs).stdout


def start_host(mode, public_key):
    image, name, ssh_port, relay_port = HOSTS[mode]
    dockerfile = "docker" if mode == "tailnet" else mode
    run(["docker", "build", "-q", "-t", image, "-f", THIS / f"{dockerfile}.Dockerfile", THIS], stdout=subprocess.DEVNULL)
    subprocess.run(["docker", "rm", "-f", name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    args = ["docker", "run", "-d", "--name", name, "--hostname", name, "--privileged",
            "-p", f"127.0.0.1:{ssh_port}:22", "-p", f"127.0.0.1:{relay_port}:443"]
    if mode == "systemd":
        args += ["--cgroupns=host", "-v", "/sys/fs/cgroup:/sys/fs/cgroup:rw", "--tmpfs", "/run", "--tmpfs", "/run/lock"]
    run([*args, image], stdout=subprocess.DEVNULL)
    run(["docker", "exec", "-i", name, "sh", "-c",
         "cat > /home/ops/.ssh/authorized_keys && chown ops:ops /home/ops/.ssh/authorized_keys && chmod 600 /home/ops/.ssh/authorized_keys"],
        input=public_key)
    deadline = time.monotonic() + 90
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", ssh_port), 2) as conn:
                if conn.recv(4).startswith(b"SSH-"):
                    break
        except OSError:
            pass
        time.sleep(1)
    else:
        raise SystemExit(f"{name} did not start SSH")
    if mode == "tailnet":
        run(["docker", "network", "connect", "--ip", "10.247.0.20", TAILNET_NET, name])
    if mode != "systemd":
        for _ in range(60):
            if subprocess.run(["docker", "exec", name, "docker", "info"], stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL).returncode == 0:
                break
            time.sleep(1)
    return name, ssh_port, relay_port


def remote(command, mode, ssh_port, key, *extra):
    ssh = ["--ssh-port", ssh_port, "-i", key, "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
           "-o", "LogLevel=ERROR"]
    return output([sys.executable, "-B", REMOTE, command, mode, "ops@127.0.0.1", *ssh, *extra])


def deploy(mode, ssh_port, relay_port, key):
    text = remote("deploy", mode, ssh_port, key,
                  "--hostname", "localhost", "--hostname", "127.0.0.1", "--name", f"Rehearsal {mode}",
                  "--issuer", ISSUER, "--client-id", CLIENT_ID, "--admin", "admin@example.org",
                  "--public-url", f"https://localhost:{relay_port}")
    decoder = json.JSONDecoder()
    placed, index = decoder.raw_decode(text.lstrip())
    report, _ = decoder.raw_decode(text.lstrip()[index:].lstrip())
    print(json.dumps({"deploy": placed, "connect": report}, indent=2))
    assert report["device_ready"] == 204 and report["anonymous_ready"] != 204
    assert report["pin"] == placed["pin"], "the presented pin differs from the reported server pin"
    return placed


def device_agent(url, pin, workdir):
    """Adds the relay to a real Agent Commander device agent with isolated state."""
    binary = workdir / "commander-network"
    if not binary.exists():
        run(["go", "build", "-o", binary, "./cmd/commander-network"], cwd=MODULE, env=dict(os.environ, GOWORK="off"))
    state = Path(tempfile.mkdtemp(prefix="acr-net-"))
    # Sign-in needs the Google Desktop client file for the relay's client ID.
    # The rehearsal stops before sign-in, so a placeholder secret is enough.
    (state / "state").mkdir(mode=0o700)
    client = state / "state" / "google-desktop-client.json"
    client.write_text(json.dumps({"installed": {"client_id": CLIENT_ID, "client_secret": "rehearsal-placeholder"}}))
    client.chmod(0o600)
    env = dict(os.environ, COMMANDER_NETWORK_STATE=str(state / "state"), COMMANDER_NETWORK_SOCKET=str(state / "network.sock"),
               AGENT_COMMANDER_SOCKET=str(state / "commander.sock"))
    daemon = subprocess.Popen([binary, "serve"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    account = None
    try:
        for _ in range(100):
            if (state / "network.sock").exists():
                break
            time.sleep(0.1)

        def tray(verb, body):
            reply = json.loads(output([binary, "tray", verb], input=json.dumps(body), env=env))
            assert reply.get("ok"), f"tray {verb} failed: {reply}"
            return reply["data"]

        probe = tray("server-probe", {"url": url})
        steps = {s["step"]: s for s in probe["steps"]}
        print(json.dumps({"probe": [{k: s.get(k) for k in ("step", "ok", "detail")} for s in probe["steps"]]}, indent=2))
        for step in ("dns", "tcp", "tls", "relay", "signin"):
            assert steps[step]["ok"], f"probe step {step} failed: {steps[step]}"
        assert steps["tls"]["pin"] == pin, "the app would pin a different certificate"
        added = tray("server-add", {"url": url, "pin": pin})
        account = "device-" + hashlib.sha256(added["url"].encode()).hexdigest()
        time.sleep(2)
        servers = tray("servers", {})["servers"]
        summary = next(s for s in servers if s["id"] == added["id"])
        print(json.dumps({"server": summary}, indent=2))
        assert summary["pin"] == pin and not summary["error"], "the device agent reported a connection error"
        assert summary["state"] == "signedOut", "the device agent did not reach the sign-in step"
        return summary
    finally:
        daemon.terminate()
        daemon.wait(10)
        shutil.rmtree(state, ignore_errors=True)
        if account and sys.platform == "darwin":
            subprocess.run(["security", "delete-generic-password", "-s", "Agent Commander Multiplayer", "-a", account],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def restart(mode, name):
    if mode == "systemd":
        run(["docker", "exec", name, "systemctl", "restart", "agent-commander-relay.service"])
    else:
        run(["docker", "exec", name, "docker", "restart", "agent-commander-relay"], stdout=subprocess.DEVNULL)


def rehearse(mode, key, public_key, workdir):
    log(f"{mode}: start a disposable remote host")
    name, ssh_port, relay_port = start_host(mode, public_key)
    log(f"{mode}: deploy over SSH and connect")
    first = deploy(mode, ssh_port, relay_port, key)
    log(f"{mode}: add the relay to an Agent Commander device agent")
    device_agent(first["url"], first["pin"], workdir)
    log(f"{mode}: restart the relay and reconnect")
    restart(mode, name)
    report = json.loads(output([sys.executable, "-B", REMOTE, "connect", first["url"], "--pin", first["pin"]]))
    print(json.dumps(report, indent=2))
    log(f"{mode}: redeploy and keep the TLS identity and configuration")
    second = deploy(mode, ssh_port, relay_port, key)
    assert second["pin"] == first["pin"], "redeploy replaced the relay identity"
    print(remote("status", mode, ssh_port, key))
    log(f"{mode}: remove the relay and keep its data")
    print(remote("remove", mode, ssh_port, key))
    try:
        output([sys.executable, "-B", REMOTE, "connect", first["url"]], stderr=subprocess.DEVNULL)
        raise AssertionError("the relay still answers after removal")
    except subprocess.CalledProcessError:
        print("The relay no longer answers.")
    return name


# --- Tailnet rehearsal -------------------------------------------------------

def headscale(*args):
    return output(["docker", "exec", HEADSCALE, "headscale", *args])


def start_tailnet():
    """A private network with a disposable Headscale on it."""
    for name in (CLIENT, HEADSCALE, TS_HOST):
        subprocess.run(["docker", "rm", "-f", "-v", name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(["docker", "network", "rm", TAILNET_NET], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    run(["docker", "network", "create", "--subnet", TAILNET_SUBNET, TAILNET_NET], stdout=subprocess.DEVNULL)
    run(["docker", "run", "-d", "--name", HEADSCALE, "--network", TAILNET_NET, "--ip", HEADSCALE_IP,
         "-v", f"{THIS / 'headscale'}:/etc/headscale:ro", "--tmpfs", "/var/lib/headscale", "--tmpfs", "/var/run/headscale",
         HEADSCALE_IMAGE, "serve"], stdout=subprocess.DEVNULL)
    for _ in range(60):
        if subprocess.run(["docker", "exec", HEADSCALE, "headscale", "users", "list"], stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL).returncode == 0:
            break
        time.sleep(1)
    else:
        raise SystemExit("the disposable Headscale did not start:\n" + output(["docker", "logs", HEADSCALE]))
    user = json.loads(headscale("users", "create", "rehearsal", "-o", "json"))["id"]

    def key(*extra):
        return json.loads(headscale("preauthkeys", "create", "-u", str(user), "-e", "1h", "-o", "json", *extra))["key"]

    return key("--tags", "tag:relay"), key()


def start_client(auth_key, workdir):
    """A second tailnet node with python, openssl, remote.py and the Linux device agent."""
    run(["docker", "build", "-q", "-t", CLIENT_IMAGE, "-f", THIS / "client.Dockerfile", THIS], stdout=subprocess.DEVNULL)
    run(["docker", "run", "-d", "--name", CLIENT, "--hostname", "rehearsal-client", "--network", TAILNET_NET,
         "--cap-add", "NET_ADMIN", "--cap-add", "NET_RAW", "--device", "/dev/net/tun",
         "--entrypoint", "tailscaled", CLIENT_IMAGE, "--state=mem:"], stdout=subprocess.DEVNULL)
    arch = {"x86_64": "amd64", "aarch64": "arm64"}[output(["docker", "exec", CLIENT, "uname", "-m"]).strip()]
    binary = workdir / f"commander-network-linux-{arch}"
    run(["go", "build", "-trimpath", "-o", binary, "./cmd/commander-network"], cwd=MODULE,
        env=dict(os.environ, GOWORK="off", GOOS="linux", GOARCH=arch, CGO_ENABLED="0"))
    run(["docker", "cp", binary, f"{CLIENT}:/usr/local/bin/commander-network"])
    run(["docker", "cp", REMOTE, f"{CLIENT}:/usr/local/bin/remote.py"])
    for _ in range(40):
        if subprocess.run(["docker", "exec", CLIENT, "tailscale", "status"], stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL).returncode in (0, 1):
            break
        time.sleep(0.5)
    run(["docker", "exec", "-i", CLIENT, "tailscale", "up", f"--login-server={LOGIN_SERVER}",
         "--hostname=rehearsal-client", "--accept-dns=true", "--auth-key=file:/dev/stdin", "--timeout=90s"],
        input=auth_key.encode())


def in_client(*args, data=None):
    return run(["docker", "exec", "-i", CLIENT, *args], input=data, stdout=subprocess.PIPE).stdout.decode()


def client_device_agent(pin):
    """Runs the Linux device agent on the client node and finds the relay through tailnet verbs."""
    env = ["env", "COMMANDER_NETWORK_STATE=/tmp/net/state", "COMMANDER_NETWORK_SOCKET=/tmp/net/network.sock",
           "AGENT_COMMANDER_SOCKET=/tmp/net/commander.sock"]
    in_client("sh", "-c", "mkdir -p -m 0700 /tmp/net/state")
    # The probe checks that sign-in could start; a placeholder secret is enough.
    client = {"installed": {"client_id": CLIENT_ID, "client_secret": "rehearsal-placeholder"}}
    in_client("sh", "-c", "umask 077 && cat > /tmp/net/state/google-desktop-client.json", data=json.dumps(client).encode())
    run(["docker", "exec", "-d", CLIENT, *env, "commander-network", "serve"])
    for _ in range(100):
        if subprocess.run(["docker", "exec", CLIENT, "test", "-S", "/tmp/net/network.sock"]).returncode == 0:
            break
        time.sleep(0.1)

    def tray(verb, body):
        reply = json.loads(in_client(*env, "commander-network", "tray", verb, data=json.dumps(body).encode()))
        assert reply.get("ok"), f"tray {verb} failed: {reply}"
        return reply["data"]

    status = tray("tailnet-status", {})
    print(json.dumps({"tailnet-status": status}, indent=2))
    assert status["running"] and status["magicDNSSuffix"] == "tail.internal", "the client is not on the tailnet"
    relays = tray("tailnet-relays", {})["relays"]
    print(json.dumps({"tailnet-relays": relays}, indent=2))
    relay = next((r for r in relays if r["name"] == RELAY_NODE), None)
    assert relay and relay["url"] == RELAY_URL and relay["online"] and not relay["added"], "the relay is not listed"
    probe = tray("server-probe", {"url": relay["url"]})
    steps = {s["step"]: s for s in probe["steps"]}
    print(json.dumps({"probe": [{k: s.get(k) for k in ("step", "ok", "detail")} for s in probe["steps"]]}, indent=2))
    for step in ("dns", "tcp", "tls", "relay", "signin"):
        assert steps[step]["ok"], f"probe step {step} failed: {steps[step]}"
    assert steps["tls"]["pin"] == pin, "the app would pin a different certificate"
    in_client("sh", "-c", "pkill commander-network || true")


def tailnet_deploy(ssh_port, key, *extra):
    text = remote("deploy", "docker", ssh_port, key, "--name", "Rehearsal tailnet", "--issuer", ISSUER,
                  "--client-id", CLIENT_ID, "--admin", "admin@example.org", "--tailnet-login-server", LOGIN_SERVER,
                  "--tailnet-hostname", RELAY_NODE, "--no-connect", *extra)
    placed = json.loads(text)
    print(json.dumps(placed, indent=2))
    assert placed["url"] == RELAY_URL and placed["pin"].startswith("sha256/"), "unexpected relay URL or pin"
    assert "tag:relay" in placed["tailnet"]["tags"], "the relay node is not tagged tag:relay"
    return placed


def rehearse_tailnet(key, public_key, workdir):
    log("tailnet: start a disposable Headscale and a remote Docker host")
    relay_key, client_key = start_tailnet()
    _, ssh_port, relay_port = start_host("tailnet", public_key)
    key_file = workdir / "relay.authkey"
    key_file.write_text(relay_key)
    key_file.chmod(0o600)
    log("tailnet: deploy over SSH with a Tailscale sidecar and no published port")
    first = tailnet_deploy(ssh_port, key, "--tailnet-auth-key-file", key_file)
    for container in ("agent-commander-relay", "agent-commander-relay-tailnet"):
        ports = output(["docker", "exec", TS_HOST, "docker", "inspect", "-f", "{{json .HostConfig.PortBindings}}",
                        container]).strip()
        assert ports in ("{}", "null"), f"{container} publishes ports: {ports}"
    log("tailnet: start a second tailnet node and check the relay from it")
    start_client(client_key, workdir)
    for port in (443, 18443):
        reached = subprocess.run(["docker", "exec", CLIENT, "python3", "-c",
                                  f"import socket; socket.create_connection(('10.247.0.20', {port}), 3)"],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
        assert not reached, f"the Docker host answers on its own address at port {port}"
    print("The relay does not answer on the Docker host's own address.")
    report = json.loads(in_client("python3", "-B", "/usr/local/bin/remote.py", "connect", RELAY_URL, "--pin", first["pin"]))
    print(json.dumps(report, indent=2))
    assert report["device_ready"] == 204 and report["anonymous_ready"] != 204
    log("tailnet: find and probe the relay with the device agent's tailnet verbs")
    client_device_agent(first["pin"])
    log("tailnet: redeploy without an auth key and keep the node and pin")
    second = tailnet_deploy(ssh_port, key)
    assert second["pin"] == first["pin"], "redeploy replaced the relay identity"
    assert second["tailnet"]["addresses"] == first["tailnet"]["addresses"], "redeploy changed the tailnet node"
    in_client("python3", "-B", "/usr/local/bin/remote.py", "connect", RELAY_URL, "--pin", first["pin"])
    print(remote("status", "docker", ssh_port, key))
    log("tailnet: remove the relay and its sidecar")
    print(remote("remove", "docker", ssh_port, key))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--mode", choices=sorted(HOSTS), action="append", help="default: systemd and docker")
    parser.add_argument("--keep", action="store_true", help="leave the test hosts running for inspection")
    args = parser.parse_args()
    started = []
    with tempfile.TemporaryDirectory(prefix="acr-rehearsal-") as tmp:
        workdir = Path(tmp)
        key = workdir / "id_ed25519"
        run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "relay-rehearsal", "-f", key])
        try:
            for mode in args.mode or ["systemd", "docker"]:
                started.append(HOSTS[mode][1])
                if mode == "tailnet":
                    started += [CLIENT, HEADSCALE]
                    rehearse_tailnet(key, key.with_suffix(".pub").read_bytes(), workdir)
                else:
                    rehearse(mode, key, key.with_suffix(".pub").read_bytes(), workdir)
            log("All rehearsals passed")
        finally:
            if not args.keep:
                for name in started:
                    subprocess.run(["docker", "rm", "-f", "-v", name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                if "tailnet" in (args.mode or []):
                    subprocess.run(["docker", "network", "rm", TAILNET_NET], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


if __name__ == "__main__":
    main()
