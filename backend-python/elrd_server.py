#!/usr/bin/env python3
"""ELRD-Backend (Python) starten – Datenschublade zwischen Alamos FE2 und der ELRD-App.

    python3 elrd_server.py                 # Verwaltung http://localhost:8080, MQTT-Broker Port 1883
    python3 elrd_server.py --http-port 9000 --mqtt-port 1884
    python3 elrd_server.py --nur-lokal     # nur von diesem Rechner erreichbar
    python3 elrd_server.py --ohne-broker   # ohne eingebauten MQTT-Broker

Einstellungen: daten/einstellungen.json (wird beim ersten Start angelegt).
Anleitung: README.md in diesem Ordner. Braucht nur Python 3.9+ (macOS: /usr/bin/python3).
"""

from __future__ import annotations

import argparse
import json
import logging
import socket
import sys
import threading
from pathlib import Path
from typing import Any

if sys.version_info < (3, 9):
    sys.exit("Python 3.9 oder neuer nötig (macOS: /usr/bin/python3 aus den Xcode-Werkzeugen).")

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
# Gemeinsame Module (Datenformat, MQTT-Client) und die Verwaltungsseite liegen im ELRD-Projekt.
sys.path.insert(0, str(REPO / "tools" / "alamos"))
sys.path.insert(0, str(HERE))
WEB_ROOT = REPO / "backend" / "src" / "ELRD.Backend" / "wwwroot"

from elrd import VERSION  # noqa: E402
from elrd.bridge import ExternalBridge  # noqa: E402
from elrd.broker import Broker  # noqa: E402
from elrd.organisations import Organisations  # noqa: E402
from elrd.push import PushService  # noqa: E402
from elrd.store import Store  # noqa: E402
from elrd.web import Backend, make_server, start_retention  # noqa: E402

# Testzugänge für den ersten Start – passen zum FE2-Simulator und zu testalarm.py.
DEV_ADMIN_KEY = "entwicklung-admin-schluessel"
DEV_ORGANISATION = ("test-rd", "Test RD")
DEV_MQTT_PASSWORD = "entwicklung-fe2"

DEFAULT_SETTINGS: dict[str, Any] = {
    "http": {"host": "0.0.0.0", "port": 8080},
    "admin_schluessel": DEV_ADMIN_KEY,
    "debug": True,
    "aufbewahrung_stunden": 24,
    "topic_praefix": "elrd",
    "broker": {"eingeschaltet": True, "host": "0.0.0.0", "port": 1883, "tls_port": None, "zertifikat": "", "schluessel": ""},
    "externer_broker": {
        "eingeschaltet": False, "host": "", "port": 8883, "tls": True,
        "benutzer": "", "passwort": "", "ca_datei": "", "client_id": "elrd-backend-py",
    },
    # Schritt 144: Push-Mitteilungen über Apple (APNs). Schlüssel: Apple-Developer-Konto ›
    # Keys › „Apple Push Notifications service“; .p8-Datei in den Ordner „daten“ legen.
    "push": {
        "eingeschaltet": False, "team_id": "", "key_id": "", "schluessel_datei": "", "bundle_id": "ELRD.App",
        "testeinsaetze": True,
    },
}


def merge(defaults: dict[str, Any], values: dict[str, Any]) -> dict[str, Any]:
    result = dict(defaults)
    for key, value in values.items():
        if isinstance(value, dict) and isinstance(defaults.get(key), dict):
            result[key] = merge(defaults[key], value)
        else:
            result[key] = value
    return result


def load_settings(path: Path) -> tuple[dict[str, Any], bool]:
    """Liest die Einstellungen; legt die Datei beim ersten Start an."""
    if path.exists():
        try:
            stored = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as error:
            sys.exit(f"{path} ist kein gültiges JSON: {error}")
        merged = merge(DEFAULT_SETTINGS, stored)
        if merged != stored:
            # Neue Einträge (z. B. „push“) sichtbar machen; vorhandene Werte bleiben.
            path.write_text(json.dumps(merged, ensure_ascii=False, indent=2), encoding="utf-8")
        return merged, False
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(DEFAULT_SETTINGS, ensure_ascii=False, indent=2), encoding="utf-8")
    return dict(DEFAULT_SETTINGS), True


def local_addresses() -> list[str]:
    """IP-Adresse(n) dieses Rechners im lokalen Netz (für die App auf dem iPad)."""
    found: list[str] = []
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
            probe.connect(("192.0.2.1", 9))  # sendet nichts, wählt nur die Schnittstelle
            found.append(probe.getsockname()[0])
    except OSError:
        pass
    name = socket.gethostname()
    if name and "." not in name:
        name += ".local"
    if name and name not in found:
        found.append(name)
    return [address for address in found if not address.startswith("127.")]


def main() -> None:
    parser = argparse.ArgumentParser(description="ELRD-Backend (Python) starten.")
    parser.add_argument("--daten", type=Path, default=HERE / "daten", help="Ordner für Einstellungen und Einsätze")
    parser.add_argument("--http-port", type=int, help="Port für App und Verwaltung (Standard 8080)")
    parser.add_argument("--mqtt-port", type=int, help="Port des eingebauten MQTT-Brokers (Standard 1883)")
    parser.add_argument("--ohne-broker", action="store_true", help="eingebauten MQTT-Broker nicht starten")
    parser.add_argument("--nur-lokal", action="store_true", help="nur von diesem Rechner erreichbar (127.0.0.1)")
    parser.add_argument("--ausfuehrlich", action="store_true", help="jede HTTP-Anfrage protokollieren")
    args = parser.parse_args()

    logging.basicConfig(format="%(asctime)s  %(message)s", datefmt="%H:%M:%S",
                        level=logging.DEBUG if args.ausfuehrlich else logging.INFO)
    settings_path = args.daten / "einstellungen.json"
    settings, first_start = load_settings(settings_path)
    bind = "127.0.0.1" if args.nur_lokal else settings["http"]["host"]
    http_port = args.http_port or int(settings["http"]["port"])
    prefix = settings["topic_praefix"]

    store = Store(args.daten)
    push = PushService(store, settings["push"], base_dir=args.daten)
    organisations = Organisations(store)
    created_key = None
    if first_start and not organisations.all():
        _, created_key, _ = organisations.create(*DEV_ORGANISATION, mqtt_password=DEV_MQTT_PASSWORD)

    backend = Backend(
        store,
        admin_key=str(settings.get("admin_schluessel") or ""),
        debug=bool(settings.get("debug", True)),
        retention_hours=int(settings.get("aufbewahrung_stunden", 24)),
        prefix=prefix,
        web_root=WEB_ROOT,
        addresses=[] if args.nur_lokal else [f"http://{a}:{http_port}" for a in local_addresses()],
        push=push,
    )

    broker_settings = settings["broker"]
    if broker_settings.get("eingeschaltet", True) and not args.ohne_broker:
        backend.broker = Broker(
            backend.ingest, backend.organisations, prefix=prefix,
            host="127.0.0.1" if args.nur_lokal else broker_settings.get("host", "0.0.0.0"),
            port=args.mqtt_port or int(broker_settings.get("port", 1883)),
            tls_port=broker_settings.get("tls_port") or None,
            certfile=broker_settings.get("zertifikat") or None,
            keyfile=broker_settings.get("schluessel") or None,
        )
        try:
            backend.broker.start()
        except OSError as error:
            sys.exit(f"MQTT-Port {backend.broker.port} ist belegt ({error.strerror}). Läuft schon Mosquitto oder ein anderes Backend? "
                     "Anderen Port mit --mqtt-port wählen oder --ohne-broker.")
    external = settings["externer_broker"]
    if external.get("eingeschaltet"):
        backend.bridge = ExternalBridge(external, backend.ingest, backend.organisations, prefix)
        backend.bridge.start()

    try:
        server = make_server(backend, bind, http_port)
    except OSError as error:
        sys.exit(f"HTTP-Port {http_port} ist belegt ({error.strerror}). Läuft das Backend schon (oder Docker)? Anderen Port mit --http-port wählen.")
    stop = threading.Event()
    start_retention(backend, stop)

    print_banner(backend, settings, settings_path, http_port, created_key, args.nur_lokal)
    try:
        server.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt:
        print("\nBeende …")
    finally:
        stop.set()
        server.server_close()
        if backend.broker:
            backend.broker.stop()
        if backend.bridge:
            backend.bridge.stop()


def print_banner(backend: Backend, settings: dict[str, Any], settings_path: Path, http_port: int, created_key: Any, local_only: bool) -> None:
    line = "─" * 72
    print(line)
    print(f" ELRD-Backend (Python) {VERSION} läuft")
    print(line)
    print(f" Verwaltung & Debug:  http://localhost:{http_port}")
    for address in backend.addresses:
        print(f" Adresse für die App: {address}")
    if local_only:
        print(" (nur lokal erreichbar – für das iPad ohne --nur-lokal starten)")
    print(f" Admin-Schlüssel:     {backend.admin_key or '– (fehlt! in einstellungen.json setzen)'}")
    if backend.broker:
        hosts = [a.split('//')[1].rsplit(':', 1)[0] for a in backend.addresses] or ["localhost"]
        tls = f", TLS auf {backend.broker.tls_port}" if backend.broker.tls_port else ""
        print(f" MQTT-Broker:         {hosts[0]}:{backend.broker.port}{tls} (eingebaut)")
        print(f" Topic für FE2:       {backend.prefix}/<organisation>/alarm, Benutzer = Organisation")
    if backend.bridge:
        print(f" Externer Broker:     {settings['externer_broker'].get('host')}:{settings['externer_broker'].get('port')}")
    if push.configured:
        print(f" Push-Mitteilungen:   an (App {push.bundle_id}, {push.status()['devices']} Geräte angemeldet)")
    elif push.enabled:
        print(f" Push-Mitteilungen:   FEHLER – {push.last_error}")
    else:
        print(" Push-Mitteilungen:   aus (einstellungen.json › push, siehe README)")
    print(f" Debug-Funktionen:    {'an' if backend.debug else 'aus'} · Einsätze werden nach {backend.retention_hours} h gelöscht")
    print(f" Einstellungen:       {settings_path}")
    if created_key:
        print(line)
        print(" Erster Start – Organisation „test-rd“ angelegt:")
        print(f"   App-Schlüssel:     {created_key}")
        print("                      (nur jetzt sichtbar – in der App eintragen; neu erzeugen auf der Verwaltungsseite)")
        print(f"   MQTT für FE2:      Benutzer test-rd, Passwort {DEV_MQTT_PASSWORD}")
    if backend.admin_key == DEV_ADMIN_KEY:
        print(line)
        print(" Hinweis: Testzugänge aktiv (Admin-Schlüssel, MQTT-Passwort von test-rd).")
        print(" Vor echtem Einsatz in einstellungen.json bzw. auf der Verwaltungsseite ändern.")
    print(line)
    print(" Beenden mit Ctrl-C")
    print(flush=True)


if __name__ == "__main__":
    main()
