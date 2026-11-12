#!/usr/bin/env python3
"""Testalarme wie Alamos FE2 senden (Datenformat V2 der externen Schnittstelle).

Wege:
  mqtt  – wie FE2 über den Broker (braucht `mosquitto_pub`, z. B. `brew install mosquitto`)
  http  – direkt an die Debug-Schnittstelle des ELRD-Backends (Admin-Schlüssel nötig)

Beispiele:
  ./testalarm.py liste
  ./testalarm.py senden vu                              # neuer Einsatz (lokaler Entwicklungs-Broker)
  ./testalarm.py senden bus --nummer 2611-4711
  ./testalarm.py aendern 2611-4711 stichwort            # RD 4 → RD 5
  ./testalarm.py aendern 2611-4711 patient
  ./testalarm.py aendern 2611-4711 fahrzeug
  ./testalarm.py schliessen 2611-4711
  ./testalarm.py ablauf vu --pause 20                   # neu → Stichwort → Fahrzeug → Patient → schließen
  ./testalarm.py senden vu --weg http --backend http://localhost:8080 --admin-key entwicklung-admin-schluessel

Broker-Einstellungen (Standard = docker-compose.dev.yml / mosquitto/dev-passwd.sh):
  --host localhost --port 1883 --benutzer test-rd --passwort entwicklung-fe2 --org test-rd
  --tls  (Port 8883, Zertifikat über die System-CAs; --cafile für eigene CA)
Auch als Umgebungsvariablen: ELRD_MQTT_HOST, ELRD_MQTT_PORT, ELRD_MQTT_USER, ELRD_MQTT_PASS,
ELRD_ORG, ELRD_BACKEND, ELRD_ADMIN_KEY.

Nur Python-Standardbibliothek. Gesendete Einsätze merkt sich das Skript in
`.zustand.json` neben dieser Datei, damit `aendern` die letzte Fassung kennt.
"""

from __future__ import annotations

import argparse
import copy
import json
import os
import random
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
SAMPLES = HERE / "beispiele"
STATE_FILE = HERE / ".zustand.json"

VEHICLE_POOL = [
    "RK SWFT 71/1", "RK SWFT 71/2", "RK SWFT 71/20", "RK SWFT 76/1", "RK SWFT 76/2",
    "JOH SWFT 71/1", "JOH SWFT 71/2", "JOH SWFT 76/1", "SAMA SWFT 71/1", "AK SWFT 71/1",
    "RK WRNCK 71/1", "RK GEOHN 71/1", "RK SWFT 72/1", "RK SWFT 72/2",
]

CHANGES = {
    "stichwort": "Stichwort erhöhen (RD 2 → RD 3)",
    "patient": "weiteren Patienten melden",
    "fahrzeug": "Fahrzeug nachalarmieren",
    "nachmeldung": "Textzeile anhängen",
    "ort": "Einsatzort leicht verschieben",
}


# MARK: Bausteine

def now_iso() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def now_ms() -> int:
    return int(time.time() * 1000)


def sample_names() -> list[str]:
    return sorted(p.stem for p in SAMPLES.glob("*.json") if p.stem not in ("schliessen", "status"))


def load_sample(name: str, number: str) -> dict:
    path = SAMPLES / f"{name}.json"
    if not path.exists():
        sys.exit(f"Beispiel „{name}“ gibt es nicht. Vorhanden: {', '.join(sample_names())}")
    text = path.read_text(encoding="utf-8")
    envelope = json.loads(text.replace("{{ID}}", number).replace("{{TIMESTAMP}}", now_iso()))
    for vehicle in envelope.get("data", {}).get("vehicles", []):
        vehicle["alarmedTime"] = now_ms()
    return envelope


def new_number() -> str:
    stamp = datetime.now().strftime("%y%m%d-%H%M%S")
    return f"T{stamp}-{random.randint(100, 999)}"


def load_state() -> dict:
    if STATE_FILE.exists():
        return json.loads(STATE_FILE.read_text(encoding="utf-8"))
    return {}


def save_state(state: dict) -> None:
    STATE_FILE.write_text(json.dumps(state, ensure_ascii=False, indent=2), encoding="utf-8")


def raise_keyword(keyword: str) -> str:
    match = re.match(r"^(.*?)(\d+)(\D*)$", keyword)
    if not match:
        return keyword + " +"
    return f"{match.group(1)}{int(match.group(2)) + 1}{match.group(3)}"


def add_message(data: dict, text: str) -> None:
    data.setdefault("message", []).append(f"{datetime.now():%H:%M} {text}")


def apply_change(envelope: dict, change: str) -> dict:
    result = copy.deepcopy(envelope)
    result["timestamp"] = now_iso()
    data = result["data"]
    if change == "stichwort":
        old = data.get("keyword", "RD 1")
        data["keyword"] = raise_keyword(old)
        add_message(data, f"Stichworterhöhung {old} → {data['keyword']}")
    elif change == "patient":
        patients = data.setdefault("patient", [])
        patients.append({"name": "", "remark": "weiterer Patient (Testskript)", "patientNumber": str(len(patients) + 1)})
        add_message(data, "Weiterer Patient gemeldet")
    elif change == "fahrzeug":
        vehicles = data.setdefault("vehicles", [])
        used = {v.get("radioName") for v in vehicles}
        name = next((v for v in VEHICLE_POOL if v not in used), f"RK SWFT 71/{len(vehicles) + 30}")
        kind = "NEF" if " 76/" in name else "KTW" if " 72/" in name else "RTW"
        vehicles.append({
            "id": name.replace(" ", "").replace("/", "-"), "name": name, "radioName": name,
            "unitType": kind, "station": name.split(" ")[1], "alarmedTime": now_ms(),
        })
        add_message(data, f"Nachalarmierung {name}")
    elif change == "nachmeldung":
        add_message(data, "Nachmeldung der Leitstelle (Testskript)")
    elif change == "ort":
        location = data.setdefault("location", {})
        coordinate = location.get("coordinate")
        if isinstance(coordinate, list) and len(coordinate) == 2:
            location["coordinate"] = [round(coordinate[0] + 0.0015, 6), round(coordinate[1] + 0.0008, 6)]
        location["additional"] = "Zufahrt über Hinterhof"
        add_message(data, "Einsatzort korrigiert")
    else:
        sys.exit(f"Unbekannte Änderung „{change}“. Möglich: {', '.join(CHANGES)}")
    return result


# MARK: Senden

def send(envelope: dict, args: argparse.Namespace) -> None:
    payload = json.dumps(envelope, ensure_ascii=False)
    number = envelope.get("data", {}).get("externalId", "?")
    if args.weg == "mqtt":
        if not shutil.which("mosquitto_pub"):
            sys.exit("mosquitto_pub fehlt (macOS: brew install mosquitto) – oder --weg http verwenden.")
        topic = f"{args.prefix}/{args.org}/alarm"
        command = ["mosquitto_pub", "-h", args.host, "-p", str(args.port), "-t", topic, "-q", "1", "-m", payload]
        if args.benutzer:
            command += ["-u", args.benutzer, "-P", args.passwort or ""]
        if args.tls:
            command += ["--cafile", args.cafile] if args.cafile else ["--capath", "/etc/ssl/certs"]
        result = subprocess.run(command, capture_output=True, text=True)
        if result.returncode != 0:
            sys.exit(f"Senden fehlgeschlagen: {result.stderr.strip() or result.returncode}")
        print(f"→ {envelope['type']} {number} an {topic} ({args.host}:{args.port})")
    else:
        if not args.admin_key:
            sys.exit("Für --weg http bitte --admin-key (oder ELRD_ADMIN_KEY) angeben.")
        url = f"{args.backend.rstrip('/')}/admin/api/debug/{args.org}/raw"
        body = json.dumps({"json": payload, "via": "direct"}).encode()
        request = urllib.request.Request(url, data=body, method="POST", headers={
            "Content-Type": "application/json", "X-Admin-Key": args.admin_key,
        })
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                answer = json.loads(response.read() or b"{}")
        except urllib.error.HTTPError as error:
            sys.exit(f"Backend antwortet {error.code}: {error.read().decode(errors='replace')}")
        except urllib.error.URLError as error:
            sys.exit(f"Backend nicht erreichbar: {error.reason}")
        print(f"→ {envelope['type']} {number}: {answer.get('message', answer)}")


def remember(number: str, envelope: dict) -> None:
    state = load_state()
    state[number] = envelope
    save_state(state)


def recall(number: str) -> dict:
    state = load_state()
    if number not in state:
        known = ", ".join(state) or "keine"
        sys.exit(f"Einsatz {number} unbekannt (gesendete: {known}). Erst mit „senden“ anlegen.")
    return state[number]


# MARK: Befehle

def command_list(_: argparse.Namespace) -> None:
    print("Beispiele:")
    for name in sample_names():
        data = json.loads((SAMPLES / f"{name}.json").read_text(encoding="utf-8"))["data"]
        print(f"  {name:<12} {data['keyword']:<6} {data['keyword_description']}")
    print("\nÄnderungen (aendern <nummer> <änderung>):")
    for key, title in CHANGES.items():
        print(f"  {key:<12} {title}")


def command_send(args: argparse.Namespace) -> None:
    number = args.nummer or new_number()
    envelope = load_sample(args.beispiel, number)
    send(envelope, args)
    remember(number, envelope)
    print(f"  Einsatznummer: {number}")


def command_change(args: argparse.Namespace) -> None:
    envelope = apply_change(recall(args.nummer), args.aenderung)
    send(envelope, args)
    remember(args.nummer, envelope)


def command_close(args: argparse.Namespace) -> None:
    recall(args.nummer)
    envelope = {"type": "CLOSE", "timestamp": now_iso(), "sender": "Testskript", "data": {"externalId": args.nummer}}
    send(envelope, args)


def command_sequence(args: argparse.Namespace) -> None:
    number = args.nummer or new_number()
    envelope = load_sample(args.beispiel, number)
    steps = ["neu", "stichwort", "fahrzeug", "patient", "nachmeldung", "schliessen"]
    for index, step in enumerate(steps):
        if index > 0:
            print(f"  … {args.pause} s warten")
            time.sleep(args.pause)
        if step == "neu":
            send(envelope, args)
        elif step == "schliessen":
            send({"type": "CLOSE", "timestamp": now_iso(), "sender": "Testskript", "data": {"externalId": number}}, args)
        else:
            envelope = apply_change(envelope, step)
            send(envelope, args)
        remember(number, envelope)
    print(f"Ablauf fertig, Einsatznummer {number}.")


def parser() -> argparse.ArgumentParser:
    env = os.environ.get
    main = argparse.ArgumentParser(description="Testalarme wie Alamos FE2 senden.", formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--weg", choices=["mqtt", "http"], default="mqtt", help="mqtt (wie FE2) oder http (Debug-Schnittstelle)")
    common.add_argument("--org", default=env("ELRD_ORG", "test-rd"), help="Kennung der Organisation (Topic)")
    common.add_argument("--host", default=env("ELRD_MQTT_HOST", "localhost"))
    common.add_argument("--port", type=int, default=int(env("ELRD_MQTT_PORT", "0")) or None)
    common.add_argument("--benutzer", default=env("ELRD_MQTT_USER", "test-rd"))
    common.add_argument("--passwort", default=env("ELRD_MQTT_PASS", "entwicklung-fe2"))
    common.add_argument("--tls", action="store_true", help="TLS (Standardport 8883)")
    common.add_argument("--cafile", help="eigene CA für TLS")
    common.add_argument("--prefix", default="elrd", help="Topic-Präfix")
    common.add_argument("--backend", default=env("ELRD_BACKEND", "http://localhost:8080"))
    common.add_argument("--admin-key", default=env("ELRD_ADMIN_KEY"))

    commands = main.add_subparsers(dest="befehl", required=True)
    commands.add_parser("liste", help="Beispiele und Änderungen zeigen").set_defaults(run=command_list)

    send_parser = commands.add_parser("senden", parents=[common], help="neuen Einsatz senden")
    send_parser.add_argument("beispiel", help="vu, intern, pflegeheim, bus")
    send_parser.add_argument("--nummer", help="Einsatznummer (Standard: neu erzeugt)")
    send_parser.set_defaults(run=command_send)

    change_parser = commands.add_parser("aendern", parents=[common], help="gesendeten Einsatz ändern")
    change_parser.add_argument("nummer")
    change_parser.add_argument("aenderung", choices=list(CHANGES))
    change_parser.set_defaults(run=command_change)

    close_parser = commands.add_parser("schliessen", parents=[common], help="Einsatz schließen (CLOSE)")
    close_parser.add_argument("nummer")
    close_parser.set_defaults(run=command_close)

    sequence = commands.add_parser("ablauf", parents=[common], help="ganzer Ablauf mit Pausen")
    sequence.add_argument("beispiel")
    sequence.add_argument("--nummer")
    sequence.add_argument("--pause", type=int, default=15, help="Sekunden zwischen den Schritten")
    sequence.set_defaults(run=command_sequence)
    return main


def main() -> None:
    args = parser().parse_args()
    if getattr(args, "port", 1) is None:
        args.port = 8883 if args.tls else 1883
    args.run(args)


if __name__ == "__main__":
    main()
