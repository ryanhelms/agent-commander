import concurrent.futures
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

spec = importlib.util.spec_from_file_location("pane", "design/verification/30-pane/measure.py")
pane = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pane)
def measure(call):
    start = time.monotonic()
    call()
    return round(1000*(time.monotonic()-start),2)

with tempfile.TemporaryDirectory(dir="/tmp", prefix="ac-lock-") as folder:
    root = Path(folder).resolve()
    state, profile, sock = root/"state", root/"profile", root/"s"
    state.mkdir(mode=0o700)
    profile.mkdir(mode=0o700)
    fake = root/"codex"
    fake.write_text('#!/bin/sh\n[ "$1" = "login" ] && [ "$2" = "status" ] || exit 3\n/usr/bin/touch entered\n/bin/sleep 1\nexit 1\n')
    fake.chmod(0o700)
    env = {k:v for k,v in os.environ.items() if not k.startswith("AGENT_COMMANDER_")}
    env.update(AGENT_COMMANDER_HOME=str(state), AGENT_COMMANDER_SOCKET=str(sock), AGENT_COMMANDER_CODEX_PROFILE=str(profile), AGENT_COMMANDER_CODEX_ACP="/usr/bin/false",AGENT_COMMANDER_CODEX=str(fake),TMUX_TMPDIR=str(root))
    with (root/"service.log").open("w") as log:
        proc = subprocess.Popen([sys.argv[1],"serve"], env=env, stdout=log, stderr=log)
        try:
            pane.wait_for_service(proc,sock)
            def runs(): return pane.api(sock,"GET","/v1/runs")
            def admit(): return pane.api(sock,"POST","/v1/runs",{"client":"codex","task":"fixture","path":str(root)},409)
            with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
                for _ in range(6):
                    mark = profile/"entered"
                    mark.unlink(missing_ok=True)
                    baseline = measure(runs)
                    attempt = pool.submit(admit)
                    deadline = time.monotonic()+2
                    while not mark.exists():
                        if attempt.done() or time.monotonic() > deadline: raise RuntimeError("probe not reached: "+str(attempt.result()))
                        time.sleep(.001)
                    during = measure(runs)
                    result = attempt.result()
                    assert any(s in str(result) for s in ("signed out", "timed out")), result
                    print(json.dumps(dict(baseline_ms=baseline,concurrent_list_ms=during, probe_timed_out="timed out" in str(result))),flush=True)
        finally:
            proc.terminate()
            proc.wait(timeout=8)
