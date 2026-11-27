"""Check connectivity from inside one participant's network namespace."""
import json
import socket
import ssl
import sys
import time

HOST = "srv01.agentmux.bytedesk.ai"


def readiness(ctx, address):
    with socket.create_connection((address, 8443), 3) as origin, ctx.wrap_socket(origin, server_hostname=HOST) as conn:
        conn.sendall(f"GET /ready HTTP/1.1\r\nHost: {HOST}:8443\r\nConnection: close\r\n\r\n".encode())
        with conn.makefile("rb") as response:
            return conn.version(), response.readline(128).strip()


if sys.argv[1]=="edge":
    ctx=ssl.create_default_context(cafile="/proof/trust.pem")
    ctx.minimum_version=ssl.TLSVersion.TLSv1_3
    ctx.load_cert_chain("/proof/client.pem","/proof/client.key")
    version, status = readiness(ctx, sys.argv[2])
    if version != "TLSv1.3" or not status.startswith(b"HTTP/1.1 204 "):
        raise RuntimeError(f"edge dispatcher unavailable: {version}, {status!r}")
    sys.exit(0)
if sys.argv[1]=="listen":
    with socket.socket() as listener:
        listener.bind(("0.0.0.0",int(sys.argv[2])))
        listener.listen(8)
        deadline=time.monotonic()+120
        while time.monotonic()<deadline:
            listener.settimeout(max(0.01,deadline-time.monotonic()))
            try:
                connection,_=listener.accept()
            except socket.timeout:
                break
            with connection: connection.sendall(b"participant-local")
relay, provider, blocked,porttext = sys.argv[1:5]
peer_port = int(porttext)
with socket.create_connection(("127.0.0.1",peer_port),2) as local:
    if local.recv(30)!=b"participant-local": raise RuntimeError("own namespace listener missing")

host = HOST
expected = {host: relay, **{n: provider for n in ("issuer.rehearsal.test","github.rehearsal.test","api.github.com","github.com")}}
for name, ip in expected.items():
    if {v[4][0] for v in socket.getaddrinfo(name,8443,socket.AF_INET,socket.SOCK_STREAM)} != {ip}:
        raise RuntimeError("unexpected DNS result for "+name)
targets=json.loads(blocked)
for service, ips in targets.items():
    port = peer_port if service.startswith("peer-") else 5432 if service == "postgres" else 4222 if service.startswith("nats-") else 8443
    for ip in ips:
        try:
            with socket.create_connection((ip,port),0.4):
                raise RuntimeError("cross-network connection reached "+service)
        except OSError:
            pass
ctx=ssl.create_default_context(cafile="/proof/trust.pem")
ctx.minimum_version=ssl.TLSVersion.TLSv1_3
try:
    _,status=readiness(ctx, host)
except (ssl.SSLError,ConnectionError):
    status=b""
if status and not status.startswith(b"HTTP/1.1 401 "):
    raise RuntimeError(f"unauthenticated readiness probe was not denied: {status!r}")
ctx.load_cert_chain("/proof/client.pem","/proof/client.key")
version,status=readiness(ctx, host)
if version!="TLSv1.3" or not status.startswith(b"HTTP/1.1 204 "):
    raise RuntimeError(f"device-authenticated TLS readiness failed: {version}, {status!r}")
print(json.dumps({"tls":version,"device_ready":204,"blocked":sorted(s for s,ips in targets.items() if ips),"offline":sorted(s for s,ips in targets.items() if not ips)}))
