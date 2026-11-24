"""Regression checks for certificate validation and the pilot's bind settings."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import prepare


class PrepareTest(unittest.TestCase):
    def test_public_configuration(self):
        with tempfile.TemporaryDirectory(prefix="commander-pilot-test-") as directory:
            root = Path(directory)
            host = "srv01.agentmux.bytedesk.ai"
            ca = prepare.authority(root, root, "test-ca")
            prepare.issue(root, ca, root, "matching", "serverAuth", "DNS:" + host)
            prepare.issue(root, ca, root, "other", "serverAuth", "DNS:other.example.test")
            prepare.openssl("req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256",
                            "-nodes", "-days", "1", "-subj", "/CN=" + host,
                            "-keyout", root / "legacy.key", "-out", root / "legacy.pem")
            chain = root / "fullchain.pem"
            chain.write_bytes((root / "matching.pem").read_bytes() + ca[1].read_bytes())
            cert = ["--certificate", chain, "--private-key", root / "matching.key"]
            email = ["--allow-email", "alice@example.test"]
            public = ["--public", *cert, *email]
            for name, args, trust, error in [
                ("trusted", public, True, None),
                ("untrusted", public, False, "relay certificate verification failed"),
                ("no-allowlist", ["--public", *cert], True, "email allowlist"),
                ("no-certificate", ["--public", *email], True, "trusted relay certificate"),
                ("empty-client", ["--client-id", ""], True, "nonempty OIDC client ID"),
                ("wrong-host", ["--certificate", root / "other.pem", "--private-key", root / "other.key"],
                 False, "relay certificate verification failed"),
                ("wrong-key", ["--certificate", chain, "--private-key", root / "other.key"],
                 True, "cannot load the relay certificate and key"),
                ("common-name-only", ["--certificate", root / "legacy.pem", "--private-key", root / "legacy.key"],
                 False, "relay certificate verification failed"),
                ("private-generated", [], False, None),
                ("private-supplied", cert, False, None),
            ]:
                with self.subTest(name=name):
                    target = root / name
                    env = dict(os.environ)
                    if trust:
                        env["SSL_CERT_FILE"] = str(ca[1])
                    command = [
                        sys.executable, "-B", prepare.__file__, target, "--hostname", host,
                        "--issuer", "https://accounts.google.com", "--client-id", "desktop-fixture", *args,
                    ]
                    proc = subprocess.run(command, capture_output=True, text=True, env=env)
                    if error:
                        self.assertNotEqual(proc.returncode, 0)
                        self.assertIn(error, proc.stderr)
                        self.assertFalse(target.exists())
                    else:
                        self.assertEqual(proc.returncode, 0, proc.stderr)
                        settings = (target / "pilot.env").read_text()
                        self.assertEqual("PILOT_BIND=0.0.0.0\nPILOT_PORT=443\n" in settings, name == "trusted")


if __name__ == "__main__":
    unittest.main()
