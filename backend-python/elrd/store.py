"""Speicher als JSON-Datei (`store.json`), gleiches Format wie das .NET-Backend.

Alles liegt im Arbeitsspeicher und wird nach jeder Änderung atomar gesichert.
Zeitpunkte als Text in UTC mit Millisekunden: `2026-11-12T20:15:00.123Z`.
"""

from __future__ import annotations

import copy
import json
import os
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Optional, TypeVar

T = TypeVar("T")


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def iso(moment: datetime) -> str:
    moment = moment.astimezone(timezone.utc)
    return moment.strftime("%Y-%m-%dT%H:%M:%S.") + f"{moment.microsecond // 1000:03d}Z"


def parse_iso(text: Optional[str]) -> Optional[datetime]:
    """ISO 8601 lesen (auch mit „Z“ – Python 3.9 kann das nicht von selbst)."""
    if not text:
        return None
    value = text.strip()
    if value.endswith(("Z", "z")):
        value = value[:-1] + "+00:00"
    # fromisoformat (3.9) verlangt 3 oder 6 Nachkommastellen.
    if "." in value:
        head, rest = value.split(".", 1)
        digits = ""
        while rest and rest[0].isdigit():
            digits, rest = digits + rest[0], rest[1:]
        value = f"{head}.{(digits + '000000')[:6]}{rest}"
    try:
        moment = datetime.fromisoformat(value)
    except ValueError:
        return None
    return moment if moment.tzinfo else moment.replace(tzinfo=timezone.utc)


class Store:
    """Organisationen und Einsätze; Zugriff nur über `read`/`write` (unter Sperre)."""

    def __init__(self, directory: Path) -> None:
        directory.mkdir(parents=True, exist_ok=True)
        self.path = directory / "store.json"
        self._lock = threading.RLock()
        self._state: dict[str, Any] = {"version": 1, "organisations": [], "alarms": []}
        if self.path.exists():
            loaded = json.loads(self.path.read_text(encoding="utf-8") or "{}")
            self._state.update({k: v for k, v in loaded.items() if k in ("version", "organisations", "alarms")})

    def read(self, reader: Callable[[dict[str, Any]], T]) -> T:
        with self._lock:
            return copy.deepcopy(reader(self._state))

    def write(self, change: Callable[[dict[str, Any]], T]) -> T:
        with self._lock:
            result = change(self._state)
            self._save()
            return copy.deepcopy(result)

    def _save(self) -> None:
        temporary = self.path.with_suffix(".tmp")
        temporary.write_text(json.dumps(self._state, ensure_ascii=False, indent=1), encoding="utf-8")
        os.replace(temporary, self.path)
        try:
            os.chmod(self.path, 0o600)  # nur für den eigenen Benutzer lesbar
        except OSError:
            pass


def alarm_dto(alarm: dict[str, Any]) -> dict[str, Any]:
    """Einsatz für die App: wie das .NET-Backend (ohne Nullwerte)."""
    keys = ("id", "externalId", "revision", "receivedAt", "updatedAt", "closedAt", "sender", "source", "isTest", "data")
    return {key: alarm[key] for key in keys if alarm.get(key) is not None}
