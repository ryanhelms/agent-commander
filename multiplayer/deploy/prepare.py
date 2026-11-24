#!/usr/bin/env python3
"""Prepare private TLS credentials and configuration for a fresh relay pilot."""
import argparse
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import ssl
import subprocess
import tempfile
from urllib.parse import urlparse

EDGES = ("edge-a", "edge-b")
BROKERS = ("nats-a", "nats-b", "nats-c")
STREAM = "COMMANDER_DELIVERIES_V1"
CONSUMER = "commander_dispatchers_v1"


def openssl(*args):
    subprocess.run(["openssl", *map(str, args)], check=True, stdout=subprocess.DEVNULL)


def subject_name(host):
    try:
        return "IP:" + str(ipaddress.ip_address(host))
    except ValueError:
        if len(host) > 253 or not all(re.fullmatch(r"[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?", part)
                                      for part in host.split(".")):
            raise ValueError("invalid relay hostname")
        return "DNS:" + host


def validate_certificate(args, hostname):
    """Check the supplied leaf and key before writing deployment credentials."""
    server = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    try:
        server.load_cert_chain(args.certificate, args.private_key, password="")
    except OSError as exc:
        raise ValueError(f"cannot load the relay certificate and key: {exc}") from exc
    if args.public:
        client = ssl.create_default_context()
    else:
        client = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        client.load_verify_locations(cafile=args.certificate)
        client.verify_flags |= ssl.VERIFY_X509_PARTIAL_CHAIN
    client.hostname_checks_common_name = False
    server.minimum_version = client.minimum_version = ssl.TLSVersion.TLSv1_3
    # A handshake over memory BIOs verifies the chain and SAN as a real client
    # would, without binding a port or contacting the pilot hostname.
    inbound, outbound = ssl.MemoryBIO(), ssl.MemoryBIO()
    origin = server.wrap_bio(outbound, inbound, server_side=True)
    device = client.wrap_bio(inbound, outbound, server_hostname=hostname.split(":", 1)[1])
    try:
        for _ in range(8):
            try:
                device.do_handshake()
            except ssl.SSLWantReadError:
                pass
            try:
                origin.do_handshake()
                return
            except ssl.SSLWantReadError:
                pass
    except ssl.SSLError as exc:
        raise ValueError(f"relay certificate verification failed: {exc}") from exc
    raise ValueError("relay certificate verification could not complete its TLS handshake")


def authority(staging, target, name):
    key, cert = staging / (name + ".key"), target / (name + ".pem")
    openssl("req", "-sha256", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256", "-pkeyopt", "ec_param_enc:named_curve",
            "-nodes", "-days", "365", "-subj", "/CN=Commander " + name,
            "-addext", "basicConstraints=critical,CA:TRUE", "-addext", "keyUsage=critical,keyCertSign,cRLSign",
            "-addext", "subjectKeyIdentifier=hash",
            "-keyout", key, "-out", cert)
    return key, cert


def issue(staging, ca, directory, name, usage, san):
    key, cert = directory / (name + ".key"), directory / (name + ".pem")
    csr, ext = staging / "req.csr", staging / "ext.cnf"
    openssl("req", "-sha256", "-new", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256", "-pkeyopt", "ec_param_enc:named_curve",
            "-nodes", "-subj", "/CN=" + name, "-keyout", key, "-out", csr)
    ext.write_text(f"basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\n"
                   f"extendedKeyUsage={usage}\nsubjectAltName={san}\n"
                   "subjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid:always\n")
    openssl("x509", "-sha256", "-req", "-in", csr, "-CA", ca[1], "-CAkey", ca[0], "-set_serial",
            str(secrets.randbits(120)), "-days", "90", "-extfile", ext, "-out", cert)


def broker_user(name, password):
    allowed = [
        "$JS.API.INFO",
        f"$JS.API.STREAM.INFO.{STREAM}", f"$JS.API.STREAM.CREATE.{STREAM}", f"$JS.API.STREAM.UPDATE.{STREAM}",
        f"$JS.API.CONSUMER.INFO.{STREAM}.{CONSUMER}", f"$JS.API.CONSUMER.CREATE.{STREAM}.{CONSUMER}",
        f"$JS.API.CONSUMER.MSG.NEXT.{STREAM}.{CONSUMER}", f"$JS.ACK.{STREAM}.{CONSUMER}.>",
        "commander.v1.delivery", "commander.v1.edge.*",
    ]
    return {"user": name, "password": password, "permissions": {
        "publish": allowed, "subscribe": ["_INBOX.>", f"commander.v1.edge.{name}"]}}


def configure(args, target, hostname, staging):
    ca = authority(staging, target, "ca")
    route_ca = authority(staging, target, "route-ca")
    postgres = target / "postgres"
    postgres.mkdir()
    db_password = secrets.token_urlsafe(32)
    (postgres / "admin-password").write_text(secrets.token_urlsafe(32) + "\n")
    (postgres / "01-owner.sql").write_text(
        f"CREATE ROLE commander LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD '{db_password}';\n"
        "ALTER DATABASE commander OWNER TO commander;\n")
    issue(staging, ca, postgres, "server", "serverAuth", "DNS:postgres")

    if not args.certificate:
        issue(staging, ca, staging, "relay", "serverAuth", hostname)
    users = []
    for name in EDGES:
        folder = target / name
        folder.mkdir()
        password = secrets.token_urlsafe(32)
        users.append(broker_user(name, password))
        shutil.copy(ca[1], folder / "ca.pem")
        shutil.copyfile(args.certificate or staging / "relay.pem", folder / "server.pem")
        shutil.copyfile(args.private_key or staging / "relay.key", folder / "server.key")
        issue(staging, ca, folder, "workload", "clientAuth", "DNS:" + name)
        (folder / "dsn").write_text(f"postgres://commander:{db_password}@postgres:5432/commander"
                                     "?sslmode=verify-full&sslrootcert=/run/relay/ca.pem\n")
        (folder / "broker-password").write_text(password + "\n")
        cfg = dict(edge=name, listen=":8443", certificate="/run/relay/server.pem", private_key="/run/relay/server.key",
                   database_url_file="/run/relay/dsn", broker_urls=[f"tls://{b}:4222" for b in BROKERS],
                   broker_user=name, broker_password_file="/run/relay/broker-password", broker_ca="/run/relay/ca.pem",
                   broker_certificate="/run/relay/workload.pem", broker_key="/run/relay/workload.key",
                   replicas=len(BROKERS), issuer=args.issuer, client_id=args.client_id, allowed_emails=args.allow_email)
        if args.issuer_ca:
            shutil.copyfile(args.issuer_ca, folder / "issuer-ca.pem")
            cfg["issuer_ca"] = "/run/relay/issuer-ca.pem"
        (folder / "edge.json").write_text(json.dumps(cfg, indent=2) + "\n")

    route_password = secrets.token_urlsafe(32)
    for name in BROKERS:
        folder = target / name
        folder.mkdir()
        (target / ("data-" + name)).mkdir()
        issue(staging, ca, folder, "server", "serverAuth", "DNS:" + name)
        issue(staging, route_ca, folder, "route", "clientAuth,serverAuth", "DNS:" + name)
        shutil.copy(ca[1], folder / "ca.pem")
        shutil.copy(route_ca[1], folder / "route-ca.pem")
        inbound = dict(cert_file="/run/broker/server.pem", key_file="/run/broker/server.key",
                       ca_file="/run/broker/ca.pem", verify=True, min_version="1.3")
        route_tls = dict(cert_file="/run/broker/route.pem", key_file="/run/broker/route.key",
                         ca_file="/run/broker/route-ca.pem", verify=True, min_version="1.3")
        cfg = dict(server_name=name, listen="0.0.0.0:4222", client_advertise=f"{name}:4222",
                   jetstream=dict(store_dir="/data", max_file_store=1 << 30, max_memory_store=64 << 20),
                   tls=inbound, authorization=dict(users=users),
                   cluster=dict(name="commander", listen="0.0.0.0:6222", advertise=f"{name}:6222",
                                authorization=dict(user="route", password=route_password), tls=route_tls,
                                routes=[f"nats://route:{route_password}@{peer}:6222" for peer in BROKERS if peer != name]))
        (folder / "nats.conf").write_text(json.dumps(cfg, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path, help="new private directory outside the checkout")
    parser.add_argument("--hostname", required=True)
    parser.add_argument("--issuer", required=True, help="HTTPS OIDC issuer accessible to edges and users")
    parser.add_argument("--client-id", required=True)
    parser.add_argument("--allow-email", action="append", default=[], help="restrict enrollment and sessions to this verified OIDC email; repeat for each pilot participant")
    parser.add_argument("--certificate", type=Path)
    parser.add_argument("--private-key", type=Path)
    parser.add_argument("--issuer-ca", type=Path)
    parser.add_argument("--public", action="store_true",
                        help="publish TCP 443 for the internet pilot and require a trusted certificate and email allowlist")
    args = parser.parse_args()
    target = args.directory.resolve()
    issuer = urlparse(args.issuer)
    if bool(args.certificate) != bool(args.private_key) or issuer.scheme != "https" or not issuer.hostname:
        parser.error("provide an HTTPS issuer and both files when supplying a relay certificate")
    if not args.client_id or any(char.isspace() for char in args.client_id):
        parser.error("provide a nonempty OIDC client ID without whitespace")
    if args.public and (not args.certificate or not args.allow_email):
        parser.error("--public requires a trusted relay certificate, its key and an email allowlist")
    try:
        hostname = subject_name(args.hostname)
        if args.certificate:
            validate_certificate(args, hostname)
    except ValueError as e:
        parser.error(str(e))
    if target.is_relative_to(Path(__file__).resolve().parents[2]) or any(c in str(target) for c in "'\n\r"):
        parser.error("choose a new external directory whose path contains no quote or newline")
    os.umask(0o077)
    target.mkdir(mode=0o700, parents=False, exist_ok=False)
    with tempfile.TemporaryDirectory(dir=target) as staging:
        configure(args, target, hostname, Path(staging))
    ingress = "PILOT_BIND=0.0.0.0\nPILOT_PORT=443\n" if args.public else ""
    (target / "pilot.env").write_text(
        f"PILOT_CONFIG_DIR='{target}'\nPILOT_UID={os.getuid()}\nPILOT_GID={os.getgid()}\n{ingress}"
    )
    print(f"Created private deployment material in {target}")


if __name__ == "__main__":
    main()
