#!/usr/bin/env python3
"""Testalarme wie Alamos FE2 senden (Datenformat V2 der externen Schnittstelle).

Mit Oberfläche: siehe fe2_simulator.py (Anleitung: ANLEITUNG-macOS.md).

Wege:
  mqtt  – wie FE2 über den Broker (eingebauter MQTT-Client, kein mosquitto_pub nötig)
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

Gesendete Einsätze merkt sich das Skript in `.zustand.json` neben dieser Datei,
damit `aendern` die letzte Fassung kennt.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import fe2_format as fe2  # noqa: E402
from elrd_backend import BackendError, send_raw  # noqa: E402
from mqtt_client import MqttError, publish_once  # noqa: E402

STATE_FILE = Path(__file__).resolve().parent / ".zustand.json"


def load_state() -> dict:
    if STATE_FILE.exists():
        return json.loads(STATE_FILE.read_text(encoding="utf-8"))
    return {}


def save_state(state: dict) -> None:
    STATE_FILE.write_text(json.dumps(state, ensure_ascii=False, indent=2), encoding="utf-8")


def send(envelope: dict, args: argparse.Namespace) -> None:
    number = envelope.get("data", {}).get("externalId", "?")
    try:
        if args.weg == "mqtt":
            topic = fe2.topic(args.prefix, args.org)
            publish_once(
                topic, fe2.to_json(envelope),
                host=args.host, port=args.port, username=args.benutzer, password=args.passwort,
                use_tls=args.tls, cafile=args.cafile,
            )
            print(f"→ {envelope['type']} {number} an {topic} ({args.host}:{args.port})")
        else:
            answer = send_raw(args.backend, args.admin_key or "", args.org, envelope)
            print(f"→ {envelope['type']} {number}: {answer.get('message', answer)}")
    except (MqttError, BackendError) as error:
        sys.exit(f"Senden fehlgeschlagen: {error}")


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


def command_list(_: argparse.Namespace) -> None:
    print("Beispiele:")
    for name in fe2.sample_names():
        print(f"  {name:<12} {fe2.sample_title(name)}")
    print("\nÄnderungen (aendern <nummer> <änderung>):")
    for key, title in fe2.CHANGES.items():
        print(f"  {key:<12} {title}")


def command_send(args: argparse.Namespace) -> None:
    try:
        envelope = fe2.load_sample(args.beispiel, args.nummer)
    except ValueError as error:
        sys.exit(str(error))
    number = envelope["data"]["externalId"]
    send(envelope, args)
    remember(number, envelope)
    print(f"  Einsatznummer: {number}")


def command_change(args: argparse.Namespace) -> None:
    envelope = fe2.apply_change(recall(args.nummer), args.aenderung)
    send(envelope, args)
    remember(args.nummer, envelope)


def command_close(args: argparse.Namespace) -> None:
    recall(args.nummer)
    send(fe2.close_message(args.nummer, sender="Testskript"), args)


def command_sequence(args: argparse.Namespace) -> None:
    envelope = fe2.load_sample(args.beispiel, args.nummer)
    number = envelope["data"]["externalId"]
    steps = ["neu", "stichwort", "fahrzeug", "patient", "nachmeldung", "schliessen"]
    for index, step in enumerate(steps):
        if index > 0:
            print(f"  … {args.pause} s warten")
            time.sleep(args.pause)
        if step == "neu":
            send(envelope, args)
        elif step == "schliessen":
            send(fe2.close_message(number, sender="Testskript"), args)
        else:
            envelope = fe2.apply_change(envelope, step)
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
    change_parser.add_argument("aenderung", choices=list(fe2.CHANGES))
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
