"""Alarme im Datenformat V2 der externen Schnittstelle von Alamos FE2.

So erzeugt das FE2-JSON-Plugin die Nachrichten, die über das MQTT-Plugin an den
ELRD-Broker gehen. Gemeinsam genutzt von `testalarm.py` (Kommandozeile) und
`fe2_simulator.py` (Oberfläche). Nur Python-Standardbibliothek.
"""

from __future__ import annotations

import copy
import json
import random
import re
import time
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
SAMPLES_DIR = HERE / "beispiele"
TEST_MARKER = "elrdTest"

# Funkrufnamen aus den mitgelieferten Stammdaten (Schweinfurt), damit die App sie zuordnet.
VEHICLE_POOL = [
    "RK SWFT 71/1", "RK SWFT 71/2", "RK SWFT 71/20", "RK SWFT 76/1", "RK SWFT 76/2",
    "JOH SWFT 71/1", "JOH SWFT 71/2", "JOH SWFT 76/1", "SAMA SWFT 71/1", "AK SWFT 71/1",
    "RK WRNCK 71/1", "RK GEOHN 71/1", "RK SWFT 72/1", "RK SWFT 72/2",
]

UNIT_TYPES = ["RTW", "NEF", "KTW", "RTH", "ITW", "KdoW", "ELW", "MTW", "GW-San", "sonstige"]

KEYWORDS = ["RD 1", "RD 2", "RD 3", "RD 4", "RD 5"]

# Schnelle Änderungen: Kennung → Beschriftung
CHANGES = {
    "stichwort": "Stichwort erhöhen",
    "fahrzeug": "Fahrzeug nachalarmieren",
    "patient": "Patient hinzufügen",
    "nachmeldung": "Nachmeldung (Text)",
    "ort": "Einsatzort korrigieren",
}


# MARK: Zeit und Kennungen

def now_iso() -> str:
    """Zeitpunkt wie FE2: lokale Zeit mit Versatz, z. B. 2026-11-12T20:15:00+01:00."""
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def now_ms() -> int:
    return int(time.time() * 1000)


def new_number() -> str:
    """Erfundene Einsatznummer, z. B. T261112-201500-123."""
    return f"T{datetime.now():%y%m%d-%H%M%S}-{random.randint(100, 999)}"


# MARK: Beispiele

def sample_names() -> list[str]:
    return sorted(p.stem for p in SAMPLES_DIR.glob("*.json") if p.stem not in ("schliessen", "status"))


def sample_title(name: str) -> str:
    data = json.loads((SAMPLES_DIR / f"{name}.json").read_text(encoding="utf-8"))["data"]
    return f"{data.get('keyword', '')} – {data.get('keyword_description', '')}"


def load_sample(name: str, number: str | None = None) -> dict:
    """Beispiel aus `beispiele/<name>.json` mit Einsatznummer und aktuellen Zeiten."""
    path = SAMPLES_DIR / f"{name}.json"
    if not path.exists():
        raise ValueError(f"Beispiel „{name}“ gibt es nicht. Vorhanden: {', '.join(sample_names())}")
    text = path.read_text(encoding="utf-8")
    envelope = json.loads(text.replace("{{ID}}", number or new_number()).replace("{{TIMESTAMP}}", now_iso()))
    for vehicle in envelope.get("data", {}).get("vehicles", []):
        vehicle["alarmedTime"] = now_ms()
    return envelope


def empty_alarm(number: str | None = None, sender: str = "FE2-Simulator", test: bool = True) -> dict:
    data: dict = {
        "externalId": number or new_number(),
        "keyword": "RD 1",
        "keyword_description": "",
        "message": [],
        "location": {},
        "units": [{"address": "ELRD"}],
        "vehicles": [],
    }
    if test:
        data["custom"] = {TEST_MARKER: "true"}
    return {"type": "ALARM", "timestamp": now_iso(), "sender": sender, "data": data}


# MARK: Bausteine

def vehicle(radio_name: str, unit_type: str | None = None, station: str | None = None) -> dict:
    """Fahrzeug wie FE2 (`vehicles[]`); Typ ohne Angabe aus dem Funkrufnamen geschätzt."""
    radio_name = radio_name.strip()
    if not unit_type:
        unit_type = "NEF" if " 76/" in radio_name else "KTW" if " 72/" in radio_name else "RTW"
    parts = radio_name.split(" ")
    return {
        "id": radio_name.replace(" ", "").replace("/", "-"),
        "name": radio_name,
        "radioName": radio_name,
        "unitType": unit_type,
        "station": station if station is not None else (parts[1] if len(parts) > 1 else ""),
        "alarmedTime": now_ms(),
    }


def patient(remark: str = "", name: str = "", destination: str = "", number: str | int | None = None) -> dict:
    entry = {"name": name, "remark": remark}
    if destination:
        entry["destination"] = destination
    if number not in (None, ""):
        entry["patientNumber"] = str(number)
    return entry


def raise_keyword(keyword: str) -> str:
    """„RD 2“ → „RD 3“; ohne Zahl wird „ +“ angehängt."""
    match = re.match(r"^(.*?)(\d+)(\D*)$", keyword)
    if not match:
        return keyword + " +"
    return f"{match.group(1)}{int(match.group(2)) + 1}{match.group(3)}"


def add_message(data: dict, text: str) -> None:
    data.setdefault("message", []).append(f"{datetime.now():%H:%M} {text}")


# MARK: Nachrichten

def apply_change(envelope: dict, change: str) -> dict:
    """Simulierte Änderung der Leitstelle – liefert die komplette neue ALARM-Nachricht."""
    result = copy.deepcopy(envelope)
    result["type"] = "ALARM"
    result["timestamp"] = now_iso()
    data = result.setdefault("data", {})
    if change == "stichwort":
        old = data.get("keyword") or "RD 1"
        data["keyword"] = raise_keyword(old)
        add_message(data, f"Stichworterhöhung {old} → {data['keyword']}")
    elif change == "patient":
        patients = data.setdefault("patient", [])
        patients.append(patient("weiterer Patient (Simulation)", number=len(patients) + 1))
        add_message(data, "Weiterer Patient gemeldet")
    elif change == "fahrzeug":
        vehicles = data.setdefault("vehicles", [])
        used = {v.get("radioName") for v in vehicles}
        name = next((v for v in VEHICLE_POOL if v not in used), f"RK SWFT 71/{len(vehicles) + 30}")
        vehicles.append(vehicle(name))
        add_message(data, f"Nachalarmierung {name}")
    elif change == "nachmeldung":
        add_message(data, "Nachmeldung der Leitstelle (Simulation)")
    elif change == "ort":
        location = data.setdefault("location", {})
        coordinate = location.get("coordinate")
        if isinstance(coordinate, list) and len(coordinate) == 2:
            location["coordinate"] = [round(coordinate[0] + 0.0015, 6), round(coordinate[1] + 0.0008, 6)]
        location["additional"] = "Zufahrt über Hinterhof"
        add_message(data, "Einsatzort korrigiert")
    else:
        raise ValueError(f"Unbekannte Änderung „{change}“. Möglich: {', '.join(CHANGES)}")
    return result


def close_message(number: str, sender: str = "FE2-Simulator") -> dict:
    return {"type": "CLOSE", "timestamp": now_iso(), "sender": sender, "data": {"externalId": number}}


def status_message(radio_name: str, status: str = "3", sender: str = "FE2-Simulator") -> dict:
    """Fahrzeugstatus (das ELRD-Backend nimmt ihn an, verarbeitet ihn aber nicht – E110)."""
    return {
        "type": "STATUS", "timestamp": now_iso(), "sender": sender,
        "data": {"status": str(status), "event": "Statuswechsel", "radioName": radio_name},
    }


def to_json(envelope: dict, pretty: bool = False) -> str:
    return json.dumps(envelope, ensure_ascii=False, indent=2 if pretty else None)


def topic(prefix: str, organisation: str) -> str:
    return f"{prefix.strip().strip('/')}/{organisation.strip()}/alarm"
