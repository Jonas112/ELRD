"""Push-Mitteilungen an die App über Apple Push Notification service (Schritt 144).

Bei einem neuen Einsatz bekommen alle Geräte der Organisation eine Mitteilung – auch
wenn die App geschlossen ist. Ohne Zusatzpakete:

- Anmeldung bei Apple mit einem Token (JWT, ES256). Die ECDSA-Signatur (P-256) ist hier
  in reinem Python umgesetzt; der Schlüssel ist die .p8-Datei aus dem Apple-Developer-Konto.
- Apple verlangt HTTP/2, das `http.client` nicht kann. Gesendet wird deshalb mit `curl`
  (auf dem Mac vorhanden, mit HTTP/2). Das Token geht über eine Konfigurationsdatei
  (nur für den eigenen Benutzer lesbar) an curl, nicht über die Befehlszeile.

Inhalt der Mitteilung: Stichwort, Beschreibung, Ort – keine Patientendaten (Sperrbildschirm).
Protokolle nennen nur Kennungen und gekürzte Gerätekennzeichen.
"""

from __future__ import annotations

import base64
import hashlib
import json
import logging
import os
import re
import secrets
import shutil
import subprocess
import tempfile
import threading
import time
from pathlib import Path
from typing import Any, Callable, Optional

from .store import Store, iso, utc_now

log = logging.getLogger("elrd.push")

HOSTS = {"production": "https://api.push.apple.com", "sandbox": "https://api.sandbox.push.apple.com"}
TOKEN_PATTERN = re.compile(r"^[0-9a-f]{64,200}$")
MAX_DEVICES_PER_ORGANISATION = 200
TOKEN_LIFETIME_SECONDS = 50 * 60  # Apple: höchstens 60 min, frühestens alle 20 min neu


# MARK: ECDSA P-256 (nur Signieren und Prüfen, für das Apple-Token)

P = 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF
A = P - 3
B = 0x5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B
N = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551
G = (0x6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296,
     0x4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5)

Point = Optional[tuple[int, int]]


def _add(p1: Point, p2: Point) -> Point:
    if p1 is None:
        return p2
    if p2 is None:
        return p1
    (x1, y1), (x2, y2) = p1, p2
    if x1 == x2 and (y1 + y2) % P == 0:
        return None
    if p1 == p2:
        slope = (3 * x1 * x1 + A) * pow(2 * y1, -1, P) % P
    else:
        slope = (y2 - y1) * pow(x2 - x1, -1, P) % P
    x3 = (slope * slope - x1 - x2) % P
    return x3, (slope * (x1 - x3) - y1) % P


def _multiply(k: int, point: Point) -> Point:
    result: Point = None
    addend = point
    while k:
        if k & 1:
            result = _add(result, addend)
        addend = _add(addend, addend)
        k >>= 1
    return result


def public_key(private: int) -> tuple[int, int]:
    point = _multiply(private, G)
    assert point is not None
    return point


def sign(message: bytes, private: int) -> bytes:
    """ES256-Signatur (r‖s, je 32 Byte) über SHA-256 der Nachricht."""
    digest = int.from_bytes(hashlib.sha256(message).digest(), "big")
    while True:
        k = secrets.randbelow(N - 1) + 1
        point = _multiply(k, G)
        assert point is not None
        r = point[0] % N
        if r == 0:
            continue
        s = pow(k, -1, N) * (digest + r * private) % N
        if s:
            return r.to_bytes(32, "big") + s.to_bytes(32, "big")


def verify(message: bytes, signature: bytes, public: tuple[int, int]) -> bool:
    if len(signature) != 64:
        return False
    r, s = int.from_bytes(signature[:32], "big"), int.from_bytes(signature[32:], "big")
    if not (0 < r < N and 0 < s < N):
        return False
    digest = int.from_bytes(hashlib.sha256(message).digest(), "big")
    w = pow(s, -1, N)
    point = _add(_multiply(digest * w % N, G), _multiply(r * w % N, public))
    return point is not None and point[0] % N == r


# MARK: Schlüsseldatei (.p8)

def _der_items(data: bytes) -> list[tuple[int, bytes]]:
    """Ein Level DER: Liste aus (Tag, Inhalt)."""
    items, index = [], 0
    while index < len(data):
        tag = data[index]
        length = data[index + 1]
        index += 2
        if length & 0x80:
            count = length & 0x7F
            length = int.from_bytes(data[index:index + count], "big")
            index += count
        items.append((tag, data[index:index + length]))
        index += length
    return items


def load_private_key(pem: str) -> int:
    """Privater Schlüssel aus einer .p8-Datei (PKCS#8) oder „EC PRIVATE KEY“ (SEC1)."""
    body = "".join(line for line in pem.strip().splitlines() if line and not line.startswith("-----"))
    try:
        der = base64.b64decode(body, validate=False)
        (tag, content), = _der_items(der)
        items = _der_items(content)
        if len(items) >= 3 and items[1][0] == 0x30 and items[2][0] == 0x04:  # PKCS#8 → SEC1 im OCTET STRING
            (tag, content), = _der_items(items[2][1])
            items = _der_items(content)
        octets = next(value for item_tag, value in items if item_tag == 0x04)
    except (ValueError, StopIteration, IndexError) as error:
        raise ValueError("Schlüsseldatei unlesbar – erwartet wird die .p8-Datei von Apple.") from error
    private = int.from_bytes(octets, "big")
    if not 0 < private < N:
        raise ValueError("Schlüssel ungültig.")
    return private


def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def make_token(team_id: str, key_id: str, private: int, issued_at: Optional[int] = None) -> str:
    header = _b64url(json.dumps({"alg": "ES256", "kid": key_id}, separators=(",", ":")).encode())
    claims = _b64url(json.dumps({"iss": team_id, "iat": int(issued_at if issued_at is not None else time.time())}, separators=(",", ":")).encode())
    signing_input = f"{header}.{claims}".encode("ascii")
    return f"{header}.{claims}.{_b64url(sign(signing_input, private))}"


# MARK: Versand

def curl_status() -> tuple[bool, str]:
    """(nutzbar, Hinweis): curl vorhanden und mit HTTP/2?"""
    path = shutil.which("curl")
    if not path:
        return False, "curl fehlt"
    try:
        output = subprocess.run([path, "--version"], capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return False, "curl nicht ausführbar"
    if "HTTP2" not in output:
        return False, "curl ohne HTTP/2"
    return True, output.splitlines()[0] if output else "curl"


def _quote(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def send_with_curl(url: str, headers: dict[str, str], body: bytes, timeout: float = 15) -> tuple[int, str]:
    """POST über HTTP/2; Antwort (Status, Text). Status 0 = nicht erreicht."""
    path = shutil.which("curl")
    if not path:
        return 0, "curl fehlt"
    handle, config = tempfile.mkstemp(prefix="elrd-push-", suffix=".conf")
    try:
        os.chmod(config, 0o600)
        with os.fdopen(handle, "w", encoding="utf-8") as file:
            for name, value in headers.items():
                file.write(f"header = {_quote(f'{name}: {value}')}\n")
            file.write(f"url = {_quote(url)}\n")
        command = [path, "--http2", "--silent", "--show-error", "--max-time", str(int(timeout)), "--config", config,
                   "--request", "POST", "--data-binary", "@-", "--write-out", "\n%{http_code}"]
        result = subprocess.run(command, input=body, capture_output=True, timeout=timeout + 5)
    except (OSError, subprocess.SubprocessError) as error:
        return 0, str(error)
    finally:
        try:
            os.unlink(config)
        except OSError:
            pass
    output = result.stdout.decode("utf-8", "replace")
    text, _, code = output.rpartition("\n")
    if result.returncode != 0 and not code.strip().isdigit():
        return 0, result.stderr.decode("utf-8", "replace").strip() or f"curl Fehler {result.returncode}"
    try:
        return int(code.strip()), text
    except ValueError:
        return 0, output


def short(token: str) -> str:
    return token[:8] + "…"


Sender = Callable[[str, dict[str, str], bytes], tuple[int, str]]


class PushService:
    """Geräte je Organisation merken und neue Einsätze melden."""

    def __init__(self, store: Store, settings: Optional[dict[str, Any]] = None, sender: Optional[Sender] = None,
                 base_dir: Optional[Path] = None) -> None:
        settings = settings or {}
        self.store = store
        self.enabled = bool(settings.get("eingeschaltet"))
        self.team_id = str(settings.get("team_id") or "").strip()
        self.key_id = str(settings.get("key_id") or "").strip()
        self.bundle_id = str(settings.get("bundle_id") or "ELRD.App").strip()
        self.include_tests = bool(settings.get("testeinsaetze", True))
        self.hosts = dict(HOSTS)
        if settings.get("host"):  # nur für Tests
            self.hosts = {name: str(settings["host"]).rstrip("/") for name in HOSTS}
        self.sender: Sender = sender or send_with_curl
        self.last_error: Optional[str] = None
        self.last_sent_at: Optional[str] = None
        self.sent = 0
        self._private: Optional[int] = None
        self._token: Optional[tuple[str, float]] = None
        self._lock = threading.Lock()
        key_file = str(settings.get("schluessel_datei") or "").strip()
        if self.enabled:
            problem = None
            if not (self.team_id and self.key_id and key_file):
                problem = "team_id, key_id und schluessel_datei eintragen."
            else:
                path = Path(key_file).expanduser()
                if not path.is_absolute() and base_dir is not None:
                    path = base_dir / path
                try:
                    self._private = load_private_key(path.read_text(encoding="utf-8"))
                except OSError:
                    problem = f"Schlüsseldatei {path.name} nicht gefunden."
                except ValueError as error:
                    problem = str(error)
            if problem is None and sender is None:
                usable, hint = curl_status()
                if not usable:
                    problem = f"Senden nicht möglich: {hint}."
            if problem:
                self.last_error = problem
                log.warning("Push-Mitteilungen aus: %s", problem)

    @property
    def configured(self) -> bool:
        return self.enabled and self._private is not None and not (self.last_error or "").startswith("Senden nicht möglich")

    # MARK: Geräte

    def register(self, organisation_id: str, token: str, environment: str) -> None:
        token = token.strip().lower()
        if not TOKEN_PATTERN.match(token):
            raise ValueError("Gerätekennzeichen ungültig (hexadezimal erwartet).")
        environment = environment if environment in HOSTS else "production"
        now = iso(utc_now())

        def change(state: dict[str, Any]) -> None:
            devices = state.setdefault("devices", [])
            existing = next((d for d in devices if d["token"] == token), None)
            if existing is not None:
                existing.update(organisationId=organisation_id, environment=environment, lastSeenAt=now)
                return
            own = [d for d in devices if d["organisationId"] == organisation_id]
            if len(own) >= MAX_DEVICES_PER_ORGANISATION:
                oldest = min(own, key=lambda d: d.get("lastSeenAt") or "")
                devices.remove(oldest)
            devices.append({"organisationId": organisation_id, "token": token, "environment": environment,
                            "registeredAt": now, "lastSeenAt": now})

        self.store.write(change)
        log.info("%s: Gerät %s für Mitteilungen angemeldet (%s)", organisation_id, short(token), environment)

    def unregister(self, organisation_id: str, token: str) -> bool:
        token = token.strip().lower()

        def change(state: dict[str, Any]) -> bool:
            devices = state.setdefault("devices", [])
            before = len(devices)
            state["devices"] = [d for d in devices if not (d["token"] == token and d["organisationId"] == organisation_id)]
            return len(state["devices"]) != before

        return self.store.write(change)

    def devices(self, organisation_id: str) -> list[dict[str, Any]]:
        return self.store.read(lambda s: [d for d in s.get("devices", []) if d["organisationId"] == organisation_id])

    def remove_organisation(self, organisation_id: str) -> None:
        self.store.write(lambda s: s.__setitem__("devices", [d for d in s.get("devices", []) if d["organisationId"] != organisation_id]))

    def status(self) -> dict[str, Any]:
        count = self.store.read(lambda s: len(s.get("devices", [])))
        return {"enabled": self.enabled, "configured": self.configured, "bundleId": self.bundle_id,
                "devices": count, "sent": self.sent, "lastSentAt": self.last_sent_at, "lastError": self.last_error}

    # MARK: Senden

    def _bearer(self) -> str:
        with self._lock:
            if self._token is None or time.time() - self._token[1] > TOKEN_LIFETIME_SECONDS:
                assert self._private is not None
                self._token = (make_token(self.team_id, self.key_id, self._private), time.time())
            return self._token[0]

    @staticmethod
    def payload(alarm: dict[str, Any]) -> dict[str, Any]:
        data = alarm.get("data") or {}
        location = data.get("location") if isinstance(data.get("location"), dict) else {}
        keyword = data.get("keyword") if isinstance(data.get("keyword"), str) else None
        description = data.get("keyword_description") if isinstance(data.get("keyword_description"), str) else None
        place = location.get("city") or location.get("street")
        parts = [p for p in (keyword, description if description != keyword else None, place if isinstance(place, str) else None) if p]
        title = "Neuer Testeinsatz (Alamos FE2)" if alarm.get("isTest") else "Neuer Einsatz aus Alamos FE2"
        return {
            "aps": {"alert": {"title": title, "body": " · ".join(parts) or "Einsatz ohne Stichwort"},
                    "sound": "default", "thread-id": "alamos"},
            "elrd": {"kind": "alamos", "alarmId": alarm.get("id"), "externalId": alarm.get("externalId")},
        }

    def send(self, organisation_id: str, payload: dict[str, Any], collapse_id: Optional[str] = None) -> dict[str, Any]:
        """An alle Geräte der Organisation; ungültige Geräte werden entfernt."""
        if not self.configured:
            return {"sent": 0, "failed": 0, "results": [], "error": self.last_error or "Push-Mitteilungen sind ausgeschaltet."}
        body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        headers = {"authorization": f"bearer {self._bearer()}", "apns-topic": self.bundle_id, "apns-push-type": "alert",
                   "apns-priority": "10", "apns-expiration": str(int(time.time()) + 3600)}
        if collapse_id:
            headers["apns-collapse-id"] = collapse_id[:64]
        sent, failed, results, invalid = 0, 0, [], []
        for device in self.devices(organisation_id):
            url = f"{self.hosts.get(device['environment'], self.hosts['production'])}/3/device/{device['token']}"
            status, text = self.sender(url, headers, body)
            reason = ""
            try:
                reason = json.loads(text).get("reason", "") if text.strip() else ""
            except (json.JSONDecodeError, AttributeError):
                reason = text.strip()[:120]
            if status == 200:
                sent += 1
            else:
                failed += 1
                if status == 410 or reason in ("BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic"):
                    invalid.append(device["token"])
                self.last_error = f"Apple: {status} {reason}".strip()
            results.append({"device": short(device["token"]), "environment": device["environment"], "status": status, "reason": reason})
        for token in invalid:
            self.unregister(organisation_id, token)
            log.info("%s: Gerät %s entfernt (von Apple abgelehnt)", organisation_id, short(token))
        if sent:
            self.sent += sent
            self.last_sent_at = iso(utc_now())
            if not failed:
                self.last_error = None
        if sent or failed:
            log.info("%s: Mitteilung an %s Geräte gesendet, %s fehlgeschlagen", organisation_id, sent, failed)
        return {"sent": sent, "failed": failed, "results": results, "error": None if not failed else self.last_error}

    def on_ingest(self, organisation_id: str, outcome: str, alarm: Optional[dict[str, Any]]) -> None:
        """Vom Eingang aufgerufen: neuer Einsatz → Mitteilung (im Hintergrund)."""
        if outcome != "Created" or alarm is None or not self.configured:
            return
        if alarm.get("isTest") and not self.include_tests:
            return
        payload = self.payload(alarm)
        collapse = f"alamos-{alarm.get('id')}"
        threading.Thread(target=self.send, args=(organisation_id, payload, collapse), name="push", daemon=True).start()
