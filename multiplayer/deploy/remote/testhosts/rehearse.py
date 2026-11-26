#!/usr/bin/env python3
"""Deploy the relay to two disposable Linux hosts over SSH and connect to each.

One host runs systemd and receives the service deployment. The other runs
Docker Engine and receives the container deployment. Both are local Docker
containers reached only through SSH, as a remote server would be. For each
host the rehearsal deploys, checks the connection, adds the relay to a real
Agent Commander device agent with isolated state, restarts the relay,
redeploys and confirms that the TLS identity survives, then removes it.

  python3 -B multiplayer/deploy/remote/testhosts/rehearse.py [--keep] [--mode docker|systemd]
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
}


def log(message):
    print(f"\n### {message}", flush=True)


def run(args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def output(args, **kwargs):
    return run(args, stdout=subprocess.PIPE, text=True, **kwargs).stdout


def start_host(mode, public_key):
    image, name, ssh_port, relay_port = HOSTS[mode]
    run(["docker", "build", "-q", "-t", image, "-f", THIS / f"{mode}.Dockerfile", THIS], stdout=subprocess.DEVNULL)
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
    if mode == "docker":
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


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--mode", choices=sorted(HOSTS), action="append")
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
                rehearse(mode, key, key.with_suffix(".pub").read_bytes(), workdir)
            log("All rehearsals passed")
        finally:
            if not args.keep:
                for name in started:
                    subprocess.run(["docker", "rm", "-f", "-v", name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


if __name__ == "__main__":
    main()
