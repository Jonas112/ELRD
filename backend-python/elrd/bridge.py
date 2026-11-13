"""Optional: Einsätze bei einem externen MQTT-Broker abholen (z. B. Mosquitto beim Hoster).

Normalerweise braucht es das nicht – der eingebaute Broker (broker.py) reicht.
Abonniert `{Präfix}/+/alarm`, verbindet nach Abbrüchen neu (2 s … 60 s).
"""

from __future__ import annotations

import logging
import threading
from typing import Any, Optional

from mqtt_client import MqttConnection, MqttError  # tools/alamos (vom Start-Skript eingebunden)

from .ingest import AlarmIngest
from .organisations import Organisations
from .store import iso, utc_now

log = logging.getLogger("elrd.extern")


class ExternalBridge:
    def __init__(self, settings: dict[str, Any], ingest: AlarmIngest, organisations: Organisations, prefix: str) -> None:
        self.settings = settings
        self.ingest = ingest
        self.organisations = organisations
        self.prefix = prefix.strip().strip("/")
        self._stop = threading.Event()
        self._connection: Optional[MqttConnection] = None
        self.last_error: Optional[str] = None
        self.connected_since: Optional[str] = None
        self.last_message_at: Optional[str] = None
        self.messages_received = 0

    @property
    def subscription(self) -> str:
        return f"{self.prefix}/+/alarm"

    @property
    def connected(self) -> bool:
        return self._connection is not None

    def start(self) -> None:
        threading.Thread(target=self._run, name="mqtt-extern", daemon=True).start()

    def stop(self) -> None:
        self._stop.set()

    def publish(self, organisation_id: str, payload: bytes) -> None:
        connection = self._connection
        if connection is None:
            raise MqttError("Externer Broker ist nicht verbunden.")
        connection.publish(f"{self.prefix}/{organisation_id}/alarm", payload, qos=0)

    def _run(self) -> None:
        delay = 2.0
        while not self._stop.is_set():
            settings = self.settings
            try:
                with MqttConnection(
                    settings.get("host", "localhost"),
                    int(settings.get("port", 8883)),
                    settings.get("benutzer") or None,
                    settings.get("passwort"),
                    use_tls=bool(settings.get("tls", True)),
                    cafile=settings.get("ca_datei") or None,
                    client_id=settings.get("client_id") or "elrd-backend-py",
                ) as connection:
                    connection.subscribe(self.subscription, qos=1)
                    self._connection = connection
                    self.connected_since = iso(utc_now())
                    self.last_error = None
                    delay = 2.0
                    log.info("Externer Broker %s:%s verbunden, abonniert %s", settings.get("host"), settings.get("port"), self.subscription)
                    connection.listen(self._handle, self._stop)
            except Exception as error:  # noqa: BLE001 – Netz/TLS/Protokoll: neu verbinden
                self.last_error = str(error)
                log.warning("Externer Broker: %s – neuer Versuch in %.0f s", error, delay)
            finally:
                self._connection = None
                self.connected_since = None
            if self._stop.wait(delay):
                return
            delay = min(60.0, delay * 2)

    def _handle(self, topic: str, payload: bytes) -> None:
        self.messages_received += 1
        self.last_message_at = iso(utc_now())
        start, end = self.prefix + "/", "/alarm"
        middle = topic[len(start):-len(end)] if topic.startswith(start) and topic.endswith(end) else ""
        if not middle or "/" in middle:
            log.warning("Unbekanntes Topic %s", topic)
            return
        if not self.organisations.exists(middle):
            log.warning("Nachricht für unbekannte Organisation %s verworfen", middle)
            return
        self.ingest.ingest(middle, payload, source="mqtt")
