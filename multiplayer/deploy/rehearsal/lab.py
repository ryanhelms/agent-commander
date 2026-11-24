#!/usr/bin/env python3
"""Run a private, three-participant Agent Commander rehearsal on the local Docker Engine."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import sys
import tempfile
import time

THIS = Path(__file__).resolve().parent
DEPLOY = THIS.parent
MODULE = DEPLOY.parent
RELAY = "srv01.agentmux.bytedesk.ai"
USERS = {"peer-a": "alice", "peer-b": "bob", "peer-c": "carol"}
ISSUER = "https://issuer.rehearsal.test:8443"
META = ".commander-rehearsal.json"
BASE = "golang:1.26-bookworm"
PYTHON_IMAGE = "python:3.13-alpine"


def run(args, **kwargs):
    return subprocess.run([str(x) for x in args], check=True, **kwargs)


def output(args, **kwargs):
    return run(args, stdout=subprocess.PIPE, text=True, **kwargs).stdout.strip()


def image_id(name):
    return output(["docker", "image", "inspect", "--format", "{{.Id}}", name])


def ensure_image(name):
    try:
        return image_id(name)
    except subprocess.CalledProcessError:
        run(["docker", "pull", name])
        return image_id(name)


def images():
    os_arch = output(["docker", "version", "--format", "{{.Server.Os}}/{{.Server.Arch}}"]).split("/")
    if os_arch[0] != "linux":
        raise ValueError("choose a local Linux Docker Engine")
    env = dict(os.environ, CGO_ENABLED="0", GOOS="linux", GOARCH=os_arch[1], GOMAXPROCS="2")
    base = ensure_image(BASE)
    for image in (PYTHON_IMAGE, "nats:2.12-alpine", "postgres:16-alpine", "nginxinc/nginx-unprivileged:1.27-alpine"):
        ensure_image(image)
    with tempfile.TemporaryDirectory(prefix="commander-rehearsal-bins-") as tmp:
        tmp = Path(tmp)
        result = {}
        run(["go", "build", "-p", "2", "-trimpath", "-buildvcs=false", "-o", tmp / "agentctl", "./cmd/agentctl"], cwd=MODULE.parent, env=env)
        (tmp / "agentctl").chmod(0o555)
        for role, binary, source, tagged in [
            ("relay", "commander-relay", "./cmd/commander-relay", False),
            ("fixture", "fixture-server", "./deploy/rehearsal/fixture", True),
            ("peer", "pilot-peer", "./cmd/pilot-peer", True),
        ]:
            args = ["go", "build", "-p", "2", "-trimpath", "-buildvcs=false"]
            if tagged:
                args += ["-tags", "pilotfixture"]
            run([*args, "-o", tmp / binary, source], cwd=MODULE, env=env)
            (tmp / binary).chmod(0o555)
            recipe = THIS / ("peer.Dockerfile" if role == "peer" else "images.Dockerfile")
            digest = hashlib.sha256(b"mode=0555" + (tmp / binary).read_bytes() + recipe.read_bytes() + base.encode())
            if role == "peer": digest.update((tmp / "agentctl").read_bytes())
            tag = "commander-rehearsal-" + role + ":" + digest.hexdigest()[:20]
            result[role] = tag
            if subprocess.run(["docker", "image", "inspect", tag], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
                continue
            args = ["docker", "build", "--network=none", "-t", tag, "-f", recipe]
            if role == "peer":
                args += ["--build-context", "binaries=" + str(tmp), "--target", "runtime"]
            else:
                args += ["--target", role]
            run([*args, tmp])
        return result


def prepare(root):
    # The production generator owns the backend TLS, broker ACLs and database setup.
    spec = importlib.util.spec_from_file_location("relay_deploy", DEPLOY / "prepare.py")
    production = importlib.util.module_from_spec(spec)
    sys.dont_write_bytecode = True
    spec.loader.exec_module(production)
    os.umask(0o077)
    project = "commander-rehearsal-" + secrets.token_hex(6)
    (root / META).write_text(json.dumps({"project": project, "version": 1}))
    work = root / "private"
    work.mkdir()
    config = work / "services"
    config.mkdir()
    ins = work / "inputs"
    ins.mkdir()
    fixture = ins / "fixture"
    fixture.mkdir()
    with tempfile.TemporaryDirectory(dir=work) as temporary:
        temp = Path(temporary)
        ca = production.authority(temp, work, "provider-ca")
        production.issue(temp, ca, fixture, "server", "serverAuth",
                         "DNS:issuer.rehearsal.test,DNS:github.rehearsal.test,DNS:api.github.com,DNS:github.com")
        production.openssl("ecparam", "-name", "prime256v1", "-param_enc", "named_curve", "-genkey", "-noout", "-out", fixture / "signing.key")
        prod_args = argparse.Namespace(certificate=None, private_key=None, issuer_ca=ca[1],
                                       issuer=ISSUER, client_id="commander-rehearsal",
                                       allow_email=[h + "@rehearsal.test" for h in USERS.values()])
        production.configure(prod_args, config, production.subject_name(RELAY), temp)
    trust = work / "trust.pem"
    trust.write_bytes((work / "provider-ca.pem").read_bytes() + (config / "ca.pem").read_bytes())
    trust.chmod(0o444)  # public CAs individually mounted inside a nonroot participant
    for user in USERS.values():
        d = ins / user
        d.mkdir()
        shutil.copyfile(trust, d / "trust.pem")
        for kind in ("browser", "github"):
            token = secrets.token_urlsafe(40) + "\n"
            (d / (kind + "-token")).write_text(token)
            (fixture / (user + "-" + kind)).write_text(token)
    probe = work / "probe"
    probe.mkdir()
    shutil.copyfile(trust, probe / "trust.pem")
    production.openssl("req", "-x509", "-sha256", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256",
                       "-pkeyopt", "ec_param_enc:named_curve", "-nodes", "-days", "1", "-subj", "/CN=rehearsal-readiness",
                       "-addext", "basicConstraints=critical,CA:FALSE", "-addext", "extendedKeyUsage=clientAuth",
                       "-addext", "keyUsage=critical,digitalSignature", "-keyout", probe / "client.key", "-out", probe / "client.pem")
    # Docker uses the invoking UID for these private host binds.
    uid, gid = os.getuid(), os.getgid()
    if uid == 0:
        uid = gid = 65532
        for directory in (probe, *[config / n for n in (*production.EDGES, *production.BROKERS)],
                          *[config / ("data-" + n) for n in production.BROKERS]):
            for path in (directory, *directory.rglob("*")):
                os.chown(path, uid, gid)
    im = images()
    settings = {"PILOT_CONFIG_DIR": config, "PILOT_UID": uid, "PILOT_GID": gid, "REHEARSAL_INPUTS": ins,
                "REHEARSAL_TRUST": trust, **{"REHEARSAL_" + key.upper() + "_IMAGE": tag for key, tag in im.items()}}
    (work / "compose.env").write_text("".join(f"{key}='{value}'\n" for key,value in settings.items()))
    return project


def project_for(root):
    meta = json.loads((root / META).read_text())
    name = meta["project"]
    if meta["version"] != 1 or not name.startswith("commander-rehearsal-") or len(name) != len("commander-rehearsal-")+12 or any(c not in "0123456789abcdef" for c in name[-12:]):
        raise ValueError("invalid rehearsal project")
    return name


def compose(root, *args):
    return ["docker","compose","--project-name",project_for(root),"--env-file",root/"private/compose.env",
            "-f",DEPLOY/"compose.yaml","-f",THIS/"compose.yaml",*args]


def ids(root):
    result = {}
    for line in output(compose(root, "ps", "--all", "--format", "json")).splitlines():
        row = json.loads(line)
        for v in row if isinstance(row,list) else [row]:
            result[v["Service"]] = v["ID"]
    return result


def wait_ready(root):
    until = time.monotonic()+150
    while time.monotonic() < until:
        try:
            # This also verifies that the broker ACLs allow the production edge
            # to provision a three-replica stream and that the fixture is running.
            if stream(root)["current"] == 3:
                output(compose(root, "exec", "-T", "fixture", "/fixture-server", "state"), stderr=subprocess.DEVNULL)
                for peer in USERS:
                    output(compose(root, "exec", "-T", peer, "pilot-peer", "info"), stderr=subprocess.DEVNULL)
                if all(edge_ready(root, edge) for edge in ("edge-a", "edge-b")):
                    return
        except (subprocess.CalledProcessError,ValueError):
            pass
        time.sleep(2)
    raise RuntimeError("the brokers, relay edges or participant processes did not become ready")


def edge_ready(root, edge):
    project = project_for(root)
    args = ["docker", "run", "--rm", "--label", "dev.agentcommander.rehearsal.helper=" + project,
            "--network", project + "_ingress",
            "--read-only", "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
            "--user", (f"{os.getuid()}:{os.getgid()}" if os.getuid() else "65532:65532"),
            "-v", str(THIS / "network_probe.py") + ":/check.py:ro",
            "-v", str(root / "private/probe") + ":/proof:ro",
            PYTHON_IMAGE, "python", "-B", "/check.py", "edge", edge]
    return subprocess.run(args, stderr=subprocess.DEVNULL).returncode == 0


def stream(root):
    return json.loads(output(compose(root, "run", "--rm", "--no-deps", "-T", "stream-probe"), stderr=subprocess.DEVNULL))


def topology(root):
    inventory=ids(root)
    selected=[*USERS,"ingress","fixture","nats-a","nats-b","nats-c","postgres","edge-a","edge-b"]
    data=json.loads(output(["docker","inspect",*[inventory[name] for name in selected]]))
    network={name:{k:v["IPAddress"] for k,v in item["NetworkSettings"]["Networks"].items()} for name,item in zip(selected,data)}
    project=project_for(root)
    labels={name:{k.removeprefix(project+"_") for k in nets} for name,nets in network.items()}
    expected={"ingress":{"ingress",*USERS.values()},"fixture":{"ingress",*USERS.values()},
              **{service:{handle} for service,handle in USERS.items()},
              **{service:{"backbone"} for service in ("postgres","nats-a","nats-b","nats-c")},
              "edge-a":{"backbone","ingress"},"edge-b":{"backbone","ingress"}}
    if labels!=expected:
        raise RuntimeError("unexpected network attachment: "+str(labels))
    for name,container in zip(selected,data):
        if container["HostConfig"]["PortBindings"] or (name in USERS and container["Config"]["User"]!="65532:65532"):
            raise RuntimeError("unexpected published port or participant identity: "+name)
    real_networks=sorted({net for nets in network.values() for net in nets})
    if not all(n["Internal"] for n in json.loads(output(["docker","network","inspect",*real_networks]))):
        raise RuntimeError("a rehearsal network has external routing")
    # Each isolated namespace has a live TCP listener. A failed connection to
    # another user's IP proves separation even when the participant uses Unix sockets.
    peer_port=30000+secrets.randbelow(20000)
    listeners=[]
    try:
        for service in USERS:
            args=["docker","run","--rm","--label","dev.agentcommander.rehearsal.helper="+project,"--detach","--network","container:"+inventory[service],
                  "--user","65532:65532","--read-only","--cap-drop","ALL","--security-opt","no-new-privileges",
                  "-v",str(THIS/"network_probe.py")+":/check.py:ro",PYTHON_IMAGE,"python","-B","/check.py","listen",str(peer_port)]
            listeners.append(output(args))
        for service,handle in USERS.items():
            name=project+"_"+handle
            targets=[other for other in [*USERS,"edge-a","edge-b","nats-a","nats-b","nats-c","postgres"] if other!=service]
            inaccessible={other: sorted(ip for ip in network[other].values() if ip) for other in targets}
            args=["docker","run","--rm","--label","dev.agentcommander.rehearsal.helper="+project,"--network","container:"+inventory[service],"--user",(f"{os.getuid()}:{os.getgid()}" if os.getuid() else "65532:65532"),
                  "--read-only","--cap-drop","ALL","--security-opt","no-new-privileges",
                  "-v",str(THIS/"network_probe.py")+":/check.py:ro","-v",str(root/"private/probe")+":/proof:ro",
                  PYTHON_IMAGE,"python","-B","/check.py",network["ingress"][name],network["fixture"][name],json.dumps(inaccessible),str(peer_port)]
            result=json.loads(output(args))
            print(json.dumps({"participant":service,**result}),flush=True)
    finally:
        if listeners:
            run(["docker","stop","-t","1",*listeners],stdout=subprocess.DEVNULL)


def quorum(root):
    before=stream(root)
    leader=before["leader"]
    if leader not in ("nats-a","nats-b","nats-c") or before["current"]!=3:
        raise RuntimeError("incomplete initial quorum")
    run(compose(root,"stop","-t","2",leader))
    try:
        until=time.monotonic()+45
        while True:
            try:
                after=stream(root)
                if after["leader"]!=leader and after["sequence"]>before["sequence"]: break
            except (subprocess.CalledProcessError,ValueError):
                pass
            if time.monotonic()>until: raise RuntimeError("surviving quorum did not acknowledge new work")
            time.sleep(1)
        topology(root)
    finally:
        run(compose(root,"start",leader))
    wait_ready(root)
    print(json.dumps({"previous":before,"after_leader_loss":after,"rejoined":stream(root)}),flush=True)


def edge_failover(root):
    edge="edge-a"
    for service in ("edge-a","edge-b"):
        if not edge_ready(root, service):
            raise RuntimeError(f"{service} failed private mTLS readiness before edge failover")
    run(compose(root,"stop","-t","4",edge))
    try:
        topology(root)
    finally:
        run(compose(root,"start",edge))
    until=time.monotonic()+60
    while not edge_ready(root, edge):
        if time.monotonic()>until:raise RuntimeError("returning edge failed private mTLS readiness")
        time.sleep(1)
    print(json.dumps({"stopped_edge":edge,"surviving_edge":"edge-b","restored_mtls_status":204}),flush=True)


def clean(root):
    project=project_for(root)
    helpers=output(["docker","ps","-q","--filter","label=dev.agentcommander.rehearsal.helper="+project]).split()
    if helpers:
        run(["docker","stop","-t","1",*helpers],stdout=subprocess.DEVNULL)
    if (root/"private/compose.env").is_file():
        run(compose(root,"--profile","prepare","--profile","checks","down","--volumes","--remove-orphans"))
    if (root/"private").exists():
        shutil.rmtree(root/"private")
    (root/META).unlink()
    if not any(root.iterdir()):root.rmdir()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action",choices=["up","compose","topology","quorum","edge","verify","down"])
    parser.add_argument("run_directory",type=Path)
    parser.add_argument("arguments",nargs=argparse.REMAINDER)
    opts=parser.parse_args()
    for setting in ("PILOT_CONFIG_DIR","PILOT_UID","PILOT_GID","PILOT_BIND","PILOT_PORT",
                    "REHEARSAL_INPUTS","REHEARSAL_TRUST","REHEARSAL_PEER_IMAGE","REHEARSAL_FIXTURE_IMAGE","REHEARSAL_RELAY_IMAGE",
                    "COMPOSE_PROFILES","COMPOSE_FILE","COMPOSE_PROJECT_NAME"):
        os.environ.pop(setting,None)
    override=os.environ.get("DOCKER_HOST","")
    if override and not override.startswith("unix://"):
        parser.error("select the local Docker Engine Unix socket")
    local=output(["docker","context","inspect","--format",'{{(index .Endpoints "docker").Host}}'])
    if not local.startswith("unix://"):
        parser.error("select the local Docker Engine Unix socket")
    root=opts.run_directory.resolve()
    if root.is_relative_to(MODULE.parent) or any(c in str(root) for c in "'\r\n"):
        parser.error("use a new private directory outside the checkout, without quotes or newlines")
    if opts.action=="up":
        # Claim the path atomically. Only its creator may remove a partial run.
        try:
            root.mkdir(mode=0o700)
        except FileExistsError:
            parser.error("up requires a new run directory")
        try:
            prepare(root)
            rendered=json.loads(output(compose(root,"config","--format","json")))
            if any(service.get("ports") for service in rendered["services"].values()) or not all(n.get("internal") for n in rendered["networks"].values()):
                raise RuntimeError("refusing a rehearsal with published ports or external routing")
            run(compose(root,"run","--rm","--no-deps","-T","prepare-volumes"))
            run(compose(root,"up","--no-build","--pull","never","-d"))
            wait_ready(root)
            print("Ready: "+str(root),flush=True)
        except BaseException:
            if (root/META).is_file():
                if (root/"private/compose.env").is_file():
                    subprocess.run(compose(root,"logs","--tail=6","edge-a","edge-b","fixture","peer-a","peer-b","peer-c"))
                clean(root)
            raise
    elif opts.action=="down":clean(root)
    elif opts.action=="compose":os.execvp("docker",[str(x) for x in compose(root,*opts.arguments)])
    elif opts.action=="topology":topology(root)
    elif opts.action=="quorum":quorum(root)
    elif opts.action=="edge":edge_failover(root)
    else:topology(root);quorum(root);edge_failover(root)


if __name__ == "__main__":
    main()
