"""HTTP: App-Schnittstelle, Verwaltung, Debug und die Verwaltungsseite.

Gleiche Aufrufe und Antworten wie das .NET-Backend (siehe backend/README.md), damit
App, FE2-Simulator und Verwaltungsseite mit beiden Backends funktionieren.
Läuft auf `http.server` (Standardbibliothek), ein Thread je Anfrage.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import logging
import mimetypes
import re
import threading
from datetime import timedelta
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Callable, Optional
from urllib.parse import parse_qs, unquote, urlparse

import fe2_format as fe2  # tools/alamos (vom Start-Skript eingebunden)

from . import VERSION
from .bridge import ExternalBridge
from .broker import Broker
from .ingest import AlarmIngest, IngestResult
from .organisations import Organisations
from .push import PushService
from .store import Store, alarm_dto, iso, parse_iso, utc_now

log = logging.getLogger("elrd.web")
ADMIN_HEADER = "X-Admin-Key"
MIN_ADMIN_KEY = 16


class HttpError(Exception):
    def __init__(self, status: int, title: str, detail: str = "") -> None:
        super().__init__(title)
        self.status, self.title, self.detail = status, title, detail


class Backend:
    """Alles, was die Anfragen brauchen."""

    def __init__(
        self,
        store: Store,
        admin_key: str,
        debug: bool = True,
        retention_hours: int = 24,
        prefix: str = "elrd",
        broker: Optional[Broker] = None,
        bridge: Optional[ExternalBridge] = None,
        web_root: Optional[Path] = None,
        addresses: Optional[list[str]] = None,
        push: Optional[PushService] = None,
    ) -> None:
        self.store = store
        self.organisations = Organisations(store)
        self.ingest = AlarmIngest(store)
        self.admin_key = admin_key
        self.debug = debug
        self.retention_hours = max(1, int(retention_hours))
        self.prefix = prefix.strip().strip("/")
        self.broker = broker
        self.bridge = bridge
        self.web_root = web_root
        self.addresses = addresses or []
        # Schritt 144: Push-Mitteilungen bei neuen Einsätzen.
        self.push = push or PushService(store)
        self.ingest.listeners.append(self.push.on_ingest)

    # MARK: Hilfen

    def topic(self, organisation_id: str) -> str:
        return f"{self.prefix}/{organisation_id}/alarm"

    def admin_ok(self, candidate: Optional[str]) -> bool:
        if len(self.admin_key or "") < MIN_ADMIN_KEY or not candidate:
            return False
        a = hashlib.sha256(self.admin_key.encode()).digest()
        b = hashlib.sha256(candidate.strip().encode()).digest()
        return hmac.compare_digest(a, b)

    def organisation_dto(self, organisation: dict[str, Any]) -> dict[str, Any]:
        count = self.store.read(lambda s: sum(1 for a in s["alarms"] if a["organisationId"] == organisation["id"]))
        dto = {
            "id": organisation["id"], "name": organisation["name"], "apiKeyHint": organisation.get("apiKeyHint", ""),
            "createdAt": organisation.get("createdAt"), "alarmCount": count, "topic": self.topic(organisation["id"]),
            "devices": len(self.push.devices(organisation["id"])),
        }
        if self.broker is not None:
            dto["mqttUser"] = organisation["id"]
        return dto

    def mqtt_status(self) -> dict[str, Any]:
        if self.bridge is not None:
            settings = self.bridge.settings
            return {
                "enabled": True, "connected": self.bridge.connected,
                "broker": f"{'mqtts' if settings.get('tls', True) else 'mqtt'}://{settings.get('host')}:{settings.get('port')} (extern)",
                "subscription": self.bridge.subscription, "lastError": self.bridge.last_error,
                "connectedSince": self.bridge.connected_since, "lastMessageAt": self.bridge.last_message_at,
                "messagesReceived": self.bridge.messages_received,
            }
        if self.broker is not None:
            status = self.broker.status()
            ports = f"Port {status['port']}" + (f", TLS {status['tlsPort']}" if status.get("tlsPort") else "")
            clients = ", ".join(f"{c['user']} ({c['address']})" for c in status["clients"]) or "keine"
            return {
                "enabled": True, "connected": status["listening"],
                "broker": f"eingebaut, {ports} – verbunden: {clients}",
                "subscription": f"{self.prefix}/<organisation>/alarm",
                "lastError": None, "connectedSince": status["since"],
                "lastMessageAt": status["lastMessageAt"], "messagesReceived": status["messagesReceived"],
            }
        return {"enabled": False, "connected": False, "broker": "–", "subscription": "–", "lastError": None,
                "connectedSince": None, "lastMessageAt": None, "messagesReceived": 0}

    def purge(self) -> int:
        limit = utc_now() - timedelta(hours=self.retention_hours)

        def change(state: dict[str, Any]) -> int:
            before = len(state["alarms"])
            state["alarms"] = [a for a in state["alarms"] if (parse_iso(a.get("updatedAt")) or utc_now()) >= limit]
            return before - len(state["alarms"])

        removed = self.store.write(change)
        if removed:
            log.info("%s Einsätze nach %s h gelöscht", removed, self.retention_hours)
        return removed

    def deliver(self, organisation_id: str, envelope: dict[str, Any], via: Optional[str]) -> tuple[int, dict[str, Any]]:
        """Testnachricht zustellen: direkt in die Schublade oder über den Broker."""
        if not self.organisations.exists(organisation_id):
            raise HttpError(404, "Organisation unbekannt")
        payload = json.dumps(envelope, ensure_ascii=False).encode("utf-8")
        if (via or "").lower() == "mqtt":
            if self.bridge is not None:
                try:
                    self.bridge.publish(organisation_id, payload)
                except Exception as error:  # noqa: BLE001
                    raise HttpError(502, "Senden über MQTT fehlgeschlagen", str(error)) from None
                return 200, {"via": "mqtt", "outcome": "Sent", "message": f"An {self.topic(organisation_id)} gesendet – kommt über das Abonnement zurück.", "alarm": None}
            if self.broker is not None:
                result = self.broker.deliver(organisation_id, payload, source="mqtt")
                return self._delivery("mqtt", result, "Über den eingebauten Broker: ")
            raise HttpError(502, "Kein Broker", "Weder eingebauter noch externer Broker ist eingeschaltet.")
        result = self.ingest.ingest(organisation_id, payload, source="debug", is_test=True)
        return self._delivery("direct", result)

    @staticmethod
    def _delivery(via: str, result: IngestResult, prefix: str = "") -> tuple[int, dict[str, Any]]:
        body = {"via": via, "outcome": result.outcome, "message": prefix + result.message,
                "alarm": alarm_dto(result.alarm) if result.alarm else None}
        return (200 if result.ok else 400), body

    def sample_infos(self) -> list[dict[str, str]]:
        infos = []
        for name in fe2.sample_names():
            data = json.loads((fe2.SAMPLES_DIR / f"{name}.json").read_text(encoding="utf-8"))["data"]
            infos.append({"id": name, "title": data.get("keyword_description", name), "keyword": data.get("keyword", "")})
        return infos


# MARK: Anfragen

Route = tuple[str, "re.Pattern[str]", str, Callable[..., Any]]


def build_routes() -> list[Route]:
    routes: list[Route] = []

    def route(method: str, pattern: str, access: str) -> Callable[[Callable[..., Any]], Callable[..., Any]]:
        def register(handler: Callable[..., Any]) -> Callable[..., Any]:
            routes.append((method, re.compile("^" + pattern + "$"), access, handler))
            return handler
        return register

    @route("GET", r"/health", "none")
    def health(backend: Backend, request: "Request") -> Any:
        mqtt = backend.mqtt_status()
        return {"status": "ok", "version": VERSION,
                "mqtt": ("connected" if mqtt["connected"] else "disconnected") if mqtt["enabled"] else "disabled"}

    # App
    @route("GET", r"/api/v1/ping", "app")
    def ping(backend: Backend, request: "Request") -> Any:
        organisation = request.organisation
        return {"organisationId": organisation["id"], "organisationName": organisation["name"],
                "serverTime": iso(utc_now()), "version": VERSION, "retentionHours": backend.retention_hours,
                "pushEnabled": backend.push.configured}

    # Schritt 144: Gerät für Push-Mitteilungen an- bzw. abmelden.
    @route("POST", r"/api/v1/devices", "app")
    def register_device(backend: Backend, request: "Request") -> Any:
        body = request.json()
        try:
            backend.push.register(request.organisation["id"], str(body.get("token") or ""), str(body.get("environment") or "production"))
        except ValueError as error:
            raise HttpError(400, "Gerät nicht angemeldet", str(error)) from None
        return {"registered": True, "pushEnabled": backend.push.configured}

    @route("DELETE", r"/api/v1/devices/(?P<token>[0-9a-fA-F]{64,200})", "app")
    def unregister_device(backend: Backend, request: "Request", token: str) -> Any:
        backend.push.unregister(request.organisation["id"], token)
        return None

    @route("GET", r"/api/v1/alarms", "app")
    def alarms(backend: Backend, request: "Request") -> Any:
        organisation_id = request.organisation["id"]
        server_time = iso(utc_now())
        since = parse_iso(request.query.get("since"))
        if request.query.get("since") and since is None:
            raise HttpError(400, "since ungültig", "ISO 8601 erwartet, z. B. 2026-11-12T20:15:00.000Z")
        include_closed = (request.query.get("includeClosed") or "true").lower() != "false"

        def select(state: dict[str, Any]) -> list[dict[str, Any]]:
            result = []
            for alarm in state["alarms"]:
                if alarm["organisationId"] != organisation_id:
                    continue
                if since is not None and (parse_iso(alarm["updatedAt"]) or since) <= since:
                    continue
                if not include_closed and alarm.get("closedAt"):
                    continue
                result.append(alarm_dto(alarm))
            return sorted(result, key=lambda a: a["updatedAt"], reverse=True)

        return {"serverTime": server_time, "alarms": backend.store.read(select)}

    @route("GET", r"/api/v1/alarms/(?P<id>[0-9a-fA-F-]{36})", "app")
    def alarm(backend: Backend, request: "Request", id: str) -> Any:
        organisation_id = request.organisation["id"]
        found = backend.store.read(lambda s: next((a for a in s["alarms"] if a["id"] == id.lower() and a["organisationId"] == organisation_id), None))
        if found is None:
            raise HttpError(404, "Nicht gefunden")
        return alarm_dto(found)

    # Verwaltung
    @route("GET", r"/admin/api/status", "admin")
    def status(backend: Backend, request: "Request") -> Any:
        organisations, alarm_count = backend.store.read(lambda s: (len(s["organisations"]), len(s["alarms"])))
        return {"version": VERSION, "debugEnabled": backend.debug, "retentionHours": backend.retention_hours,
                "mqtt": backend.mqtt_status(), "organisations": organisations, "alarms": alarm_count,
                "builtInBroker": backend.broker is not None, "addresses": backend.addresses, "push": backend.push.status()}

    @route("GET", r"/admin/api/organisations", "admin")
    def organisations(backend: Backend, request: "Request") -> Any:
        return [backend.organisation_dto(o) for o in backend.organisations.all()]

    @route("POST", r"/admin/api/organisations", "admin")
    def create_organisation(backend: Backend, request: "Request") -> Any:
        body = request.json()
        try:
            organisation, key, password = backend.organisations.create(body.get("id", ""), body.get("name", ""))
        except ValueError as error:
            raise HttpError(400, "Organisation nicht angelegt", str(error)) from None
        result = {"organisation": backend.organisation_dto(organisation), "apiKey": key}
        if backend.broker is not None:
            result["mqttPassword"] = password
        return result

    @route("POST", r"/admin/api/organisations/(?P<org>[^/]+)/key", "admin")
    def renew_key(backend: Backend, request: "Request", org: str) -> Any:
        key = backend.organisations.renew_key(org)
        organisation = backend.organisations.get(org)
        if key is None or organisation is None:
            raise HttpError(404, "Nicht gefunden")
        return {"organisation": backend.organisation_dto(organisation), "apiKey": key}

    @route("POST", r"/admin/api/organisations/(?P<org>[^/]+)/mqtt-password", "admin")
    def renew_mqtt(backend: Backend, request: "Request", org: str) -> Any:
        password = backend.organisations.renew_mqtt_password(org)
        organisation = backend.organisations.get(org)
        if password is None or organisation is None:
            raise HttpError(404, "Nicht gefunden")
        return {"organisation": backend.organisation_dto(organisation), "mqttPassword": password}

    @route("DELETE", r"/admin/api/organisations/(?P<org>[^/]+)", "admin")
    def delete_organisation(backend: Backend, request: "Request", org: str) -> Any:
        if not backend.organisations.delete(org):
            raise HttpError(404, "Nicht gefunden")
        backend.push.remove_organisation(org)
        return None

    @route("POST", r"/admin/api/organisations/(?P<org>[^/]+)/push-test", "admin")
    def push_test(backend: Backend, request: "Request", org: str) -> Any:
        if not backend.organisations.exists(org):
            raise HttpError(404, "Nicht gefunden")
        if not backend.push.configured:
            raise HttpError(400, "Push-Mitteilungen nicht eingerichtet", backend.push.last_error or "In den Einstellungen push.eingeschaltet auf true setzen.")
        if not backend.push.devices(org):
            raise HttpError(400, "Keine Geräte", "In der App unter Einstellungen › Alamos FE2 den Abruf einschalten; die App meldet sich dann an.")
        payload = {"aps": {"alert": {"title": "Test-Mitteilung (ELRD-Backend)", "body": "Push-Mitteilungen kommen an."}, "sound": "default",
                           "thread-id": "alamos"}, "elrd": {"kind": "test"}}
        return backend.push.send(org, payload)

    # Debug
    @route("GET", r"/admin/api/debug/info", "debug")
    def info(backend: Backend, request: "Request") -> Any:
        changes = [{"id": key, "title": title} for key, title in fe2.CHANGES.items()]
        changes.append({"id": "close", "title": "Einsatz schließen (CLOSE)"})
        return {"samples": backend.sample_infos(), "changes": changes}

    @route("GET", r"/admin/api/debug/(?P<org>[^/]+)/alarms", "debug")
    def debug_alarms(backend: Backend, request: "Request", org: str) -> Any:
        def select(state: dict[str, Any]) -> list[dict[str, Any]]:
            found = [dict(alarm_dto(a), organisationId=org) for a in state["alarms"] if a["organisationId"] == org]
            return sorted(found, key=lambda a: a["updatedAt"], reverse=True)
        return backend.store.read(select)

    @route("POST", r"/admin/api/debug/(?P<org>[^/]+)/alarms", "debug")
    def debug_create(backend: Backend, request: "Request", org: str) -> Any:
        body = request.json()
        try:
            envelope = fe2.load_sample(body.get("sampleId") or "vu")
        except ValueError as error:
            raise HttpError(400, "Unbekannte Vorlage", str(error)) from None
        envelope["sender"] = "ELRD-Debug"
        return backend.deliver(org, envelope, body.get("via"))

    @route("POST", r"/admin/api/debug/(?P<org>[^/]+)/alarms/(?P<id>[0-9a-fA-F-]{36})/simulate", "debug")
    def debug_simulate(backend: Backend, request: "Request", org: str, id: str) -> Any:
        body = request.json()
        alarm = backend.store.read(lambda s: next((a for a in s["alarms"] if a["id"] == id.lower() and a["organisationId"] == org), None))
        if alarm is None:
            raise HttpError(404, "Nicht gefunden")
        change = body.get("change") or ""
        if change == "close":
            envelope = fe2.close_message(alarm["externalId"], sender="ELRD-Debug")
        else:
            try:
                envelope = fe2.apply_change({"type": "ALARM", "sender": "ELRD-Debug", "data": alarm["data"]}, change)
            except ValueError as error:
                raise HttpError(400, "Unbekannte Änderung", str(error)) from None
        return backend.deliver(org, envelope, body.get("via"))

    @route("POST", r"/admin/api/debug/(?P<org>[^/]+)/raw", "debug")
    def debug_raw(backend: Backend, request: "Request", org: str) -> Any:
        body = request.json()
        try:
            envelope = json.loads(body.get("json") or "")
        except json.JSONDecodeError as error:
            raise HttpError(400, "Kein gültiges JSON", str(error)) from None
        if not isinstance(envelope, dict):
            raise HttpError(400, "JSON-Objekt erwartet")
        return backend.deliver(org, envelope, body.get("via"))

    @route("DELETE", r"/admin/api/debug/(?P<org>[^/]+)/alarms/(?P<id>[0-9a-fA-F-]{36})", "debug")
    def debug_delete(backend: Backend, request: "Request", org: str, id: str) -> Any:
        def change(state: dict[str, Any]) -> bool:
            before = len(state["alarms"])
            state["alarms"] = [a for a in state["alarms"] if not (a["organisationId"] == org and a["id"] == id.lower())]
            return len(state["alarms"]) < before
        if not backend.store.write(change):
            raise HttpError(404, "Nicht gefunden")
        return None

    @route("DELETE", r"/admin/api/debug/(?P<org>[^/]+)/alarms", "debug")
    def debug_clear(backend: Backend, request: "Request", org: str) -> Any:
        def change(state: dict[str, Any]) -> int:
            before = len(state["alarms"])
            state["alarms"] = [a for a in state["alarms"] if a["organisationId"] != org]
            return before - len(state["alarms"])
        return {"removed": backend.store.write(change)}

    return routes


ROUTES = build_routes()


class Request:
    def __init__(self, handler: "Handler", query: dict[str, str]) -> None:
        self.handler = handler
        self.query = query
        self.organisation: dict[str, Any] = {}
        self._body: Optional[dict[str, Any]] = None

    def json(self) -> dict[str, Any]:
        if self._body is None:
            length = int(self.handler.headers.get("Content-Length") or 0)
            if length > 2 * 1024 * 1024:
                raise HttpError(413, "Anfrage zu groß")
            raw = self.handler.rfile.read(length) if length else b""
            try:
                parsed = json.loads(raw.decode("utf-8")) if raw else {}
            except (UnicodeDecodeError, json.JSONDecodeError):
                raise HttpError(400, "Kein gültiges JSON") from None
            self._body = parsed if isinstance(parsed, dict) else {}
        return self._body


class Handler(BaseHTTPRequestHandler):
    server_version = "ELRD-Backend-Python"
    backend: Backend  # wird von make_server gesetzt
    # HTTP/1.0: Verbindung nach jeder Antwort schließen – einfach und robust.

    def do_GET(self) -> None:  # noqa: N802
        self._dispatch("GET")

    def do_POST(self) -> None:  # noqa: N802
        self._dispatch("POST")

    def do_DELETE(self) -> None:  # noqa: N802
        self._dispatch("DELETE")

    def log_message(self, format: str, *args: Any) -> None:  # noqa: A002
        # Nur Methode, Pfad ohne Abfrage und Status – keine Inhalte. Bei unlesbaren
        # Anfragen fehlen command/path noch (http.server ruft das dann trotzdem auf).
        path = getattr(self, "path", None)
        log.debug("%s %s", getattr(self, "command", None) or "-", urlparse(path).path if path else "-")

    def log_error(self, format: str, *args: Any) -> None:  # noqa: A002
        """Unlesbare Anfrage (z. B. HTTPS auf dem HTTP-Port) verständlich melden."""
        raw = getattr(self, "raw_requestline", b"") or b""
        client = self.client_address[0] if self.client_address else "?"
        if raw.startswith(b"\x16\x03"):
            log.warning("HTTPS-Anfrage von %s auf dem HTTP-Port – in der App die Adresse mit „http://“ eintragen.", client)
        else:
            log.warning("Unlesbare Anfrage von %s abgelehnt.", client)

    def _dispatch(self, method: str) -> None:
        url = urlparse(self.path)
        path = unquote(url.path)
        query = {key: values[-1] for key, values in parse_qs(url.query).items()}
        try:
            for route_method, pattern, access, handler in ROUTES:
                match = pattern.match(path)
                if match and route_method == method:
                    request = Request(self, query)
                    self._authorize(access, request)
                    result = handler(self.backend, request, **match.groupdict())
                    if isinstance(result, tuple):
                        self._json(result[0], result[1])
                    elif result is None:
                        self._send(204, b"", None)
                    else:
                        self._json(200, result)
                    return
            if method == "GET" and not path.startswith(("/api/", "/admin/api/")):
                self._static(path)
                return
            raise HttpError(404, "Nicht gefunden")
        except HttpError as error:
            self._json(error.status, {"title": error.title, "detail": error.detail, "status": error.status})
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception:  # noqa: BLE001
            log.exception("Fehler bei %s %s", method, path)
            self._json(500, {"title": "Interner Fehler", "status": 500})

    def _authorize(self, access: str, request: Request) -> None:
        backend = self.backend
        if access == "app":
            header = self.headers.get("Authorization") or ""
            key = header[7:] if header.lower().startswith("bearer ") else (self.headers.get("X-Api-Key") or "")
            organisation = backend.organisations.authenticate(key)
            if organisation is None:
                raise HttpError(401, "Schlüssel ungültig", "App-Schlüssel fehlt oder ist falsch.")
            request.organisation = organisation
        elif access in ("admin", "debug"):
            if len(backend.admin_key or "") < MIN_ADMIN_KEY:
                raise HttpError(503, "Verwaltung gesperrt", f"Admin-Schlüssel ist nicht gesetzt (mindestens {MIN_ADMIN_KEY} Zeichen).")
            if not backend.admin_ok(self.headers.get(ADMIN_HEADER)):
                raise HttpError(401, "Admin-Schlüssel falsch")
            if access == "debug" and not backend.debug:
                raise HttpError(404, "Debug ausgeschaltet", "In den Einstellungen debug auf true setzen.")

    def _static(self, path: str) -> None:
        root = self.backend.web_root
        if root is None or not root.is_dir():
            raise HttpError(404, "Verwaltungsseite fehlt", "Ordner backend/src/ELRD.Backend/wwwroot nicht gefunden.")
        relative = "index.html" if path in ("", "/") else path.lstrip("/")
        target = (root / relative).resolve()
        if root.resolve() not in target.parents or not target.is_file():
            raise HttpError(404, "Nicht gefunden")
        content_type = mimetypes.guess_type(str(target))[0] or "application/octet-stream"
        if content_type.startswith("text/") or content_type in ("application/javascript", "application/json"):
            content_type += "; charset=utf-8"
        self._send(200, target.read_bytes(), content_type)

    def _json(self, status: int, body: Any) -> None:
        self._send(status, json.dumps(body, ensure_ascii=False).encode("utf-8"), "application/json; charset=utf-8")

    def _send(self, status: int, data: bytes, content_type: Optional[str]) -> None:
        try:
            phrase = HTTPStatus(status).phrase
        except ValueError:
            phrase = ""
        self.send_response(status, phrase)
        if content_type:
            self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if data and self.command != "HEAD":
            self.wfile.write(data)


def make_server(backend: Backend, host: str, port: int) -> ThreadingHTTPServer:
    handler = type("BoundHandler", (Handler,), {"backend": backend})
    server = ThreadingHTTPServer((host, port), handler)
    server.daemon_threads = True
    return server


def start_retention(backend: Backend, stop: threading.Event) -> None:
    def run() -> None:
        while True:
            backend.purge()
            if stop.wait(600):
                return
    threading.Thread(target=run, name="aufbewahrung", daemon=True).start()
