"""Organisationen (Kunden): App-Schlüssel und MQTT-Zugang für den eingebauten Broker.

Gespeichert werden nur Hashes: App-Schlüssel als SHA-256 (wie .NET, damit
`store.json` austauschbar bleibt), MQTT-Passwörter mit PBKDF2.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import re
import secrets
from typing import Any, Optional

from .store import Store, iso, utc_now

ID_PATTERN = re.compile(r"^[a-z0-9][a-z0-9-]{1,39}$")
PBKDF2_ROUNDS = 120_000


def new_api_key() -> str:
    return "elrd_" + base64.urlsafe_b64encode(secrets.token_bytes(30)).decode("ascii")


def new_mqtt_password() -> str:
    return secrets.token_urlsafe(18)


def hash_api_key(key: str) -> str:
    return base64.b64encode(hashlib.sha256(key.encode("utf-8")).digest()).decode("ascii")


def hash_password(password: str, salt: Optional[bytes] = None) -> str:
    salt = salt or secrets.token_bytes(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, PBKDF2_ROUNDS)
    return f"pbkdf2${PBKDF2_ROUNDS}${base64.b64encode(salt).decode()}${base64.b64encode(digest).decode()}"


def verify_password(password: str, stored: Optional[str]) -> bool:
    if not stored or not stored.startswith("pbkdf2$"):
        return False
    try:
        _, rounds, salt, digest = stored.split("$")
        expected = base64.b64decode(digest)
        actual = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), base64.b64decode(salt), int(rounds))
    except (ValueError, TypeError):
        return False
    return hmac.compare_digest(expected, actual)


class Organisations:
    def __init__(self, store: Store) -> None:
        self.store = store

    def all(self) -> list[dict[str, Any]]:
        return self.store.read(lambda s: sorted(s["organisations"], key=lambda o: o["name"].lower()))

    def get(self, organisation_id: str) -> Optional[dict[str, Any]]:
        return self.store.read(lambda s: next((o for o in s["organisations"] if o["id"] == organisation_id), None))

    def exists(self, organisation_id: str) -> bool:
        return self.get(organisation_id) is not None

    def create(self, organisation_id: str, name: str, mqtt_password: Optional[str] = None) -> tuple[dict[str, Any], str, str]:
        """Legt an; liefert (Organisation, App-Schlüssel, MQTT-Passwort) – Klartext nur jetzt."""
        organisation_id = (organisation_id or "").strip().lower()
        name = (name or "").strip()
        if not ID_PATTERN.match(organisation_id):
            raise ValueError("Kennung: 2–40 Zeichen, nur a–z, 0–9 und „-“.")
        if not name:
            raise ValueError("Bitte einen Namen angeben.")
        key = new_api_key()
        password = mqtt_password or new_mqtt_password()
        organisation = {
            "id": organisation_id,
            "name": name,
            "apiKeyHash": hash_api_key(key),
            "apiKeyHint": key[-4:],
            "createdAt": iso(utc_now()),
            "mqttPasswordHash": hash_password(password),
        }

        def add(state: dict[str, Any]) -> None:
            if any(o["id"] == organisation_id for o in state["organisations"]):
                raise ValueError(f"Kennung „{organisation_id}“ gibt es schon.")
            state["organisations"].append(organisation)

        self.store.write(add)
        return dict(organisation), key, password

    def renew_key(self, organisation_id: str) -> Optional[str]:
        key = new_api_key()

        def change(state: dict[str, Any]) -> bool:
            for organisation in state["organisations"]:
                if organisation["id"] == organisation_id:
                    organisation["apiKeyHash"] = hash_api_key(key)
                    organisation["apiKeyHint"] = key[-4:]
                    return True
            return False

        return key if self.store.write(change) else None

    def renew_mqtt_password(self, organisation_id: str, password: Optional[str] = None) -> Optional[str]:
        password = password or new_mqtt_password()
        hashed = hash_password(password)

        def change(state: dict[str, Any]) -> bool:
            for organisation in state["organisations"]:
                if organisation["id"] == organisation_id:
                    organisation["mqttPasswordHash"] = hashed
                    return True
            return False

        return password if self.store.write(change) else None

    def delete(self, organisation_id: str) -> bool:
        def change(state: dict[str, Any]) -> bool:
            before = len(state["organisations"])
            state["organisations"] = [o for o in state["organisations"] if o["id"] != organisation_id]
            state["alarms"] = [a for a in state["alarms"] if a["organisationId"] != organisation_id]
            return len(state["organisations"]) < before

        return self.store.write(change)

    def authenticate(self, key: Optional[str]) -> Optional[dict[str, Any]]:
        """Organisation zum App-Schlüssel."""
        if not key or not key.strip():
            return None
        candidate = base64.b64decode(hash_api_key(key.strip()))
        for organisation in self.store.read(lambda s: s["organisations"]):
            if hmac.compare_digest(base64.b64decode(organisation["apiKeyHash"]), candidate):
                return organisation
        return None

    def check_mqtt(self, username: str, password: str) -> bool:
        """MQTT-Anmeldung am eingebauten Broker: Benutzer = Kennung der Organisation."""
        organisation = self.get(username)
        return organisation is not None and verify_password(password, organisation.get("mqttPasswordHash"))
