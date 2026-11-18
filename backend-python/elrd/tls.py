"""HTTPS für das ELRD-Backend (Schritt 153).

Zertifikat und Schlüssel kommen entweder aus den Einstellungen (z. B. von Let's Encrypt)
oder werden beim ersten Start selbst erzeugt – mit `openssl`, das auf dem Mac vorhanden
ist. Ein selbst erzeugtes Zertifikat kennt iPadOS nicht; die App vertraut ihm, wenn in
ihren Einstellungen der SHA-256-Fingerabdruck eingetragen ist (wird beim Start angezeigt).
"""

from __future__ import annotations

import hashlib
import ipaddress
import logging
import os
import shutil
import socket
import ssl
import subprocess
import tempfile
from pathlib import Path
from typing import Iterable, Optional

log = logging.getLogger("elrd.tls")

CERT_NAME = "elrd-backend.crt"
KEY_NAME = "elrd-backend.key"
VALID_DAYS = 825  # Apple: höchstens 825 Tage für TLS-Zertifikate


def alt_names(extra: Iterable[str], addresses: Iterable[str]) -> list[str]:
    """Namen und Adressen fürs Zertifikat: localhost, Rechnername, lokale IPs, eigene Namen."""
    names: list[str] = []
    host = socket.gethostname().split(".")[0]
    for name in ["localhost", "127.0.0.1", host, f"{host}.local", *addresses, *extra]:
        name = str(name).strip()
        if name and name not in names:
            names.append(name)
    return names


def _san_entry(name: str) -> str:
    try:
        ipaddress.ip_address(name)
        return f"IP:{name}"
    except ValueError:
        return f"DNS:{name}"


def generate(directory: Path, names: list[str], common_name: str = "ELRD-Backend") -> tuple[Path, Path]:
    """Selbst signiertes Zertifikat (RSA 2048, SHA-256) mit den Namen erzeugen."""
    openssl = shutil.which("openssl")
    if not openssl:
        raise RuntimeError("openssl fehlt – Zertifikat und Schlüssel in den Einstellungen angeben (https.zertifikat / https.schluessel).")
    directory.mkdir(parents=True, exist_ok=True)
    cert, key = directory / CERT_NAME, directory / KEY_NAME
    config = "\n".join([
        "[req]", "distinguished_name = dn", "x509_extensions = ext", "prompt = no",
        "[dn]", f"CN = {common_name}",
        "[ext]", "basicConstraints = critical,CA:FALSE", "keyUsage = critical,digitalSignature,keyEncipherment",
        "extendedKeyUsage = serverAuth", "subjectAltName = " + ",".join(_san_entry(n) for n in names), "",
    ])
    handle, config_path = tempfile.mkstemp(suffix=".cnf")
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as file:
            file.write(config)
        subprocess.run(
            [openssl, "req", "-x509", "-newkey", "rsa:2048", "-sha256", "-nodes", "-days", str(VALID_DAYS),
             "-keyout", str(key), "-out", str(cert), "-config", config_path],
            check=True, capture_output=True, timeout=60,
        )
    except subprocess.CalledProcessError as error:
        raise RuntimeError("Zertifikat konnte nicht erzeugt werden: " + error.stderr.decode("utf-8", "replace").strip()[-300:]) from None
    finally:
        os.unlink(config_path)
    os.chmod(key, 0o600)
    log.info("Selbst signiertes Zertifikat erzeugt (%s Namen)", len(names))
    return cert, key


def fingerprint(cert: Path) -> str:
    """SHA-256-Fingerabdruck des (ersten) Zertifikats, „AB:CD:…“ wie in Safari/Schlüsselbund."""
    pem = cert.read_text(encoding="utf-8")
    start = pem.index("-----BEGIN CERTIFICATE-----")
    end = pem.index("-----END CERTIFICATE-----", start) + len("-----END CERTIFICATE-----")
    digest = hashlib.sha256(ssl.PEM_cert_to_DER_cert(pem[start:end])).hexdigest().upper()
    return ":".join(digest[i:i + 2] for i in range(0, len(digest), 2))


def context(cert: Path, key: Path) -> ssl.SSLContext:
    ctx = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(str(cert), str(key))
    return ctx


class TlsSetup:
    """Zertifikat aus den Einstellungen oder selbst erzeugt (im Datenordner unter „tls“)."""

    def __init__(self, settings: dict, data_dir: Path, addresses: Iterable[str]) -> None:
        cert = str(settings.get("zertifikat") or "").strip()
        key = str(settings.get("schluessel") or "").strip()
        self.self_signed = not (cert and key)
        if self.self_signed:
            directory = data_dir / "tls"
            self.cert, self.key = directory / CERT_NAME, directory / KEY_NAME
            if not (self.cert.exists() and self.key.exists()):
                generate(directory, alt_names(settings.get("namen") or [], addresses))
        else:
            self.cert = Path(cert).expanduser()
            self.key = Path(key).expanduser()
            if not self.cert.is_absolute():
                self.cert = data_dir / self.cert
            if not self.key.is_absolute():
                self.key = data_dir / self.key
        self.context = context(self.cert, self.key)
        self.fingerprint = fingerprint(self.cert)


def wrap_server(server, ctx: ssl.SSLContext):  # noqa: ANN001, ANN201 – ThreadingHTTPServer
    """HTTP-Server auf TLS umstellen; Handshake erst im Bearbeitungs-Thread, damit ein
    langsamer Client das Annehmen weiterer Verbindungen nicht blockiert."""
    server.socket = ctx.wrap_socket(server.socket, server_side=True, do_handshake_on_connect=False)
    return server
