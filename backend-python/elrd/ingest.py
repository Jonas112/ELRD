"""Eingang für Nachrichten im Datenformat V2 der externen Schnittstelle von Alamos FE2.

Wie das .NET-Backend: `ALARM` (neu oder Aktualisierung über `data.externalId`),
`CLOSE`, `STATUS` (ignoriert, E110). Ohne Umschlag wird das Objekt als `data`
gelesen; JSON als Text verpackt wird ausgepackt. Protokolle nennen nur Kennungen.
"""

from __future__ import annotations

import copy
import json
import logging
import uuid
from dataclasses import dataclass
from datetime import datetime
from typing import Any, Callable, Optional

from .store import Store, iso, utc_now

MAX_PAYLOAD_BYTES = 512 * 1024
TEST_MARKER = "elrdTest"
log = logging.getLogger("elrd.eingang")


@dataclass
class IngestResult:
    outcome: str  # Created, Updated, Closed, Unchanged, Ignored, Rejected
    message: str
    alarm: Optional[dict[str, Any]] = None

    @property
    def ok(self) -> bool:
        return self.outcome != "Rejected"


def _text(source: Any, name: str) -> Optional[str]:
    if not isinstance(source, dict):
        return None
    value = source.get(name)
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return str(value)
    return value if isinstance(value, str) else None


class AlarmIngest:
    def __init__(self, store: Store, clock: Callable[[], datetime] = utc_now) -> None:
        self.store = store
        self.clock = clock

    def ingest(self, organisation_id: str, payload: bytes, source: str, is_test: bool = False) -> IngestResult:
        if len(payload) > MAX_PAYLOAD_BYTES:
            return self._reject(organisation_id, "Nachricht ist größer als 512 KB.")
        try:
            root = json.loads(payload.decode("utf-8-sig"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            return self._reject(organisation_id, "Kein gültiges JSON. Ist im JSON-Plugin eine Verschlüsselung (Passwort) gesetzt? Bitte leer lassen.")
        if isinstance(root, str):
            try:
                root = json.loads(root)
            except json.JSONDecodeError:
                return self._reject(organisation_id, "Text enthält kein JSON.")
        if not isinstance(root, dict):
            return self._reject(organisation_id, "JSON-Objekt erwartet.")

        kind = (_text(root, "type") or "ALARM").strip().upper()
        data = root.get("data") if isinstance(root.get("data"), dict) else None
        if data is None and "type" not in root:
            data = root  # kein Umschlag
        sender = _text(root, "sender")

        if kind == "ALARM":
            if data is None:
                return self._reject(organisation_id, "ALARM ohne data-Objekt.")
            return self._upsert(organisation_id, data, sender, source, is_test)
        if kind == "CLOSE":
            return self._close(organisation_id, _text(data, "externalId") if data else None)
        if kind == "STATUS":
            return IngestResult("Ignored", "Fahrzeugstatus wird nicht verarbeitet (E110).")
        return IngestResult("Ignored", f"Typ „{kind}“ wird nicht verarbeitet.")

    def _upsert(self, organisation_id: str, data: dict[str, Any], sender: Optional[str], source: str, is_test: bool) -> IngestResult:
        now = iso(self.clock())
        stored = copy.deepcopy(data)
        external_id = _text(stored, "externalId")
        if not external_id or not external_id.strip():
            external_id = "elrd-" + uuid.uuid4().hex[:12]
            stored["externalId"] = external_id
        custom = stored.get("custom") if isinstance(stored.get("custom"), dict) else {}
        is_test = is_test or str(custom.get(TEST_MARKER, "")) == "true"

        def change(state: dict[str, Any]) -> IngestResult:
            existing = next((a for a in state["alarms"] if a["organisationId"] == organisation_id and a["externalId"] == external_id), None)
            if existing is None:
                alarm = {
                    "id": str(uuid.uuid4()),
                    "organisationId": organisation_id,
                    "externalId": external_id,
                    "revision": 1,
                    "sender": sender,
                    "receivedAt": now,
                    "updatedAt": now,
                    "closedAt": None,
                    "source": source,
                    "isTest": is_test,
                    "data": stored,
                }
                state["alarms"].append(alarm)
                return IngestResult("Created", "Neuer Einsatz.", alarm)
            if existing["data"] == stored and not existing.get("closedAt"):
                return IngestResult("Unchanged", "Keine Änderung.", existing)
            existing["data"] = stored
            existing["revision"] += 1
            existing["updatedAt"] = now
            existing["sender"] = sender or existing.get("sender")
            existing["source"] = source
            existing["isTest"] = existing.get("isTest") or is_test
            existing["closedAt"] = None  # neue Daten zu geschlossenem Einsatz: wieder offen
            return IngestResult("Updated", f"Aktualisierung (Stand {existing['revision']}).", existing)

        result = self.store.write(change)
        self._log(organisation_id, result)
        return result

    def _close(self, organisation_id: str, external_id: Optional[str]) -> IngestResult:
        if not external_id:
            return self._reject(organisation_id, "CLOSE ohne data.externalId.")
        now = iso(self.clock())

        def change(state: dict[str, Any]) -> IngestResult:
            existing = next((a for a in state["alarms"] if a["organisationId"] == organisation_id and a["externalId"] == external_id), None)
            if existing is None:
                return IngestResult("Ignored", "Einsatz zum Schließen nicht gefunden.")
            if existing.get("closedAt"):
                return IngestResult("Unchanged", "Schon geschlossen.", existing)
            existing["closedAt"] = now
            existing["updatedAt"] = now
            existing["revision"] += 1
            return IngestResult("Closed", "Einsatz geschlossen.", existing)

        result = self.store.write(change)
        self._log(organisation_id, result)
        return result

    def _reject(self, organisation_id: str, message: str) -> IngestResult:
        log.warning("Nachricht für %s abgelehnt: %s", organisation_id, message)
        return IngestResult("Rejected", message)

    @staticmethod
    def _log(organisation_id: str, result: IngestResult) -> None:
        alarm = result.alarm or {}
        log.info("%s: %s %s (Stand %s)", organisation_id, result.outcome, alarm.get("id", "–"), alarm.get("revision", "–"))
