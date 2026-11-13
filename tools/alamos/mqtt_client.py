"""Kleiner MQTT-3.1.1-Client zum Senden (wie das MQTT-Plugin von FE2).

Kann: verbinden (optional TLS, Benutzer/Passwort), mit QoS 0 oder 1 senden,
abonnieren und empfangen (für das Python-Backend mit externem Broker), trennen.
Nur Python-Standardbibliothek – kein `paho-mqtt`, kein `mosquitto_pub`. Python 3.9+.
"""

from __future__ import annotations

import select
import socket
import ssl
import struct
import threading
import time
import uuid
from typing import Callable, Optional

CONNACK_ERRORS = {
    1: "Broker unterstützt MQTT 3.1.1 nicht.",
    2: "Client-ID abgelehnt.",
    3: "Broker nicht verfügbar.",
    4: "Benutzername oder Passwort falsch.",
    5: "Anmeldung abgelehnt – Benutzername oder Passwort falsch bzw. keine Berechtigung.",
}


class MqttError(Exception):
    """Fehler mit verständlichem deutschen Text."""


def _string(text: str) -> bytes:
    data = text.encode("utf-8")
    if len(data) > 0xFFFF:
        raise MqttError("Text zu lang.")
    return struct.pack("!H", len(data)) + data


def encode_remaining_length(length: int) -> bytes:
    if length < 0 or length > 268_435_455:
        raise MqttError("Nachricht zu groß.")
    out = bytearray()
    while True:
        digit = length % 128
        length //= 128
        if length > 0:
            digit |= 0x80
        out.append(digit)
        if length == 0:
            return bytes(out)


def packet(header: int, body: bytes) -> bytes:
    return bytes([header]) + encode_remaining_length(len(body)) + body


class MqttConnection:
    def __init__(
        self,
        host: str,
        port: int,
        username: Optional[str] = None,
        password: Optional[str] = None,
        use_tls: bool = False,
        cafile: Optional[str] = None,
        insecure: bool = False,
        client_id: Optional[str] = None,
        timeout: float = 10,
    ) -> None:
        self.host = host
        self.port = port
        self.username = username or None
        self.password = password
        self.use_tls = use_tls
        self.cafile = cafile or None
        self.insecure = insecure
        self.client_id = client_id or f"fe2-sim-{uuid.uuid4().hex[:8]}"
        self.timeout = timeout
        self._socket: Optional[socket.socket] = None
        self._packet_id = 0
        self._send_lock = threading.Lock()
        self._received: list[tuple[str, bytes]] = []
        self._qos2: set[int] = set()
        self.keep_alive = 30

    # MARK: Ablauf

    def __enter__(self) -> "MqttConnection":
        try:
            self.connect()
        except BaseException:
            self._drop()
            raise
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    def connect(self) -> None:
        try:
            raw = socket.create_connection((self.host, self.port), timeout=self.timeout)
        except socket.gaierror:
            raise MqttError(f"Broker „{self.host}“ nicht gefunden.") from None
        except (ConnectionRefusedError, TimeoutError, socket.timeout):
            raise MqttError(f"Broker {self.host}:{self.port} nicht erreichbar.") from None
        except OSError as error:
            raise MqttError(f"Verbindung fehlgeschlagen: {error.strerror or error}") from None
        if self.use_tls:
            context = ssl.create_default_context(cafile=self.cafile)
            if self.insecure:
                context.check_hostname = False
                context.verify_mode = ssl.CERT_NONE
            try:
                raw = context.wrap_socket(raw, server_hostname=self.host)
            except ssl.SSLCertVerificationError as error:
                raw.close()
                raise MqttError(
                    f"Zertifikat des Brokers ungültig ({error.verify_message}). "
                    "Unter macOS mit python.org-Python einmal „Install Certificates.command“ ausführen."
                ) from None
            except (ssl.SSLError, OSError) as error:
                raw.close()
                raise MqttError(f"TLS fehlgeschlagen: {error}") from None
        self._socket = raw

        flags = 0x02  # Clean Session
        payload = _string(self.client_id)
        if self.username:
            flags |= 0x80
            payload += _string(self.username)
            if self.password is not None:
                flags |= 0x40
                payload += _string(self.password)
        body = _string("MQTT") + bytes([4, flags]) + struct.pack("!H", self.keep_alive) + payload
        self._send(packet(0x10, body))
        header, response = self._read_packet()
        if header & 0xF0 != 0x20 or len(response) < 2:
            raise MqttError("Broker antwortet nicht mit CONNACK – ist das wirklich ein MQTT-Port?")
        code = response[1]
        if code != 0:
            raise MqttError(CONNACK_ERRORS.get(code, f"Verbindung abgelehnt (Code {code})."))

    def publish(self, topic: str, payload: bytes | str, qos: int = 1, retain: bool = False) -> None:
        if isinstance(payload, str):
            payload = payload.encode("utf-8")
        header = 0x30 | (qos << 1) | (1 if retain else 0)
        body = _string(topic)
        packet_id = 0
        if qos > 0:
            self._packet_id = self._packet_id % 0xFFFF + 1
            packet_id = self._packet_id
            body += struct.pack("!H", packet_id)
        self._send(packet(header, body + payload))
        if qos == 1:
            while True:
                kind, response = self._read_packet()
                if kind & 0xF0 == 0x40 and struct.unpack("!H", response[:2])[0] == packet_id:
                    return
        # Mosquitto meldet fehlende Schreibrechte (ACL) bei MQTT 3.1.1 nicht zurück.

    def _drop(self) -> None:
        """Socket ohne DISCONNECT schließen (nach fehlgeschlagener Anmeldung)."""
        if self._socket is not None:
            self._socket.close()
            self._socket = None

    def subscribe(self, topic_filter: str, qos: int = 1) -> int:
        """Abonniert; liefert die gewährte QoS. Fehler, wenn der Broker ablehnt (ACL)."""
        self._packet_id = self._packet_id % 0xFFFF + 1
        packet_id = self._packet_id
        self._send(packet(0x82, struct.pack("!H", packet_id) + _string(topic_filter) + bytes([qos])))
        while True:
            kind, body = self._read_packet()
            if kind & 0xF0 == 0x90 and struct.unpack("!H", body[:2])[0] == packet_id:
                granted = body[2] if len(body) > 2 else 0x80
                if granted == 0x80:
                    raise MqttError(f"Broker verweigert das Abonnement „{topic_filter}“ (Rechte/ACL prüfen).")
                return granted
            self._handle_incoming(kind, body)

    def listen(self, on_message: Callable[[str, bytes], None], stop: threading.Event) -> None:
        """Empfängt bis `stop` gesetzt ist; hält die Verbindung mit PINGREQ offen."""
        assert self._socket is not None
        last_ping = last_received = time.monotonic()
        while not stop.is_set():
            for topic, payload in self._received:
                on_message(topic, payload)
            self._received.clear()
            now = time.monotonic()
            if now - last_received > self.keep_alive * 1.5:
                raise MqttError("Broker antwortet nicht mehr.")
            if now - last_ping > self.keep_alive / 2:
                self._send(packet(0xC0, b""))
                last_ping = now
            pending = isinstance(self._socket, ssl.SSLSocket) and self._socket.pending() > 0
            if not pending:
                readable, _, _ = select.select([self._socket], [], [], 1)
                if not readable:
                    continue
            kind, body = self._read_packet()
            last_received = time.monotonic()
            self._handle_incoming(kind, body)

    def _handle_incoming(self, kind: int, body: bytes) -> None:
        if kind & 0xF0 == 0x30:  # PUBLISH
            qos = (kind >> 1) & 0x03
            length = struct.unpack_from("!H", body, 0)[0]
            topic = body[2:2 + length].decode("utf-8", errors="replace")
            offset = 2 + length
            packet_id = 0
            if qos:
                packet_id = struct.unpack_from("!H", body, offset)[0]
                offset += 2
            if qos == 1:
                self._send(packet(0x40, struct.pack("!H", packet_id)))
            elif qos == 2:
                self._send(packet(0x50, struct.pack("!H", packet_id)))
                if packet_id in self._qos2:
                    return
                self._qos2.add(packet_id)
            self._received.append((topic, body[offset:]))
        elif kind & 0xF0 == 0x60:  # PUBREL
            packet_id = struct.unpack_from("!H", body, 0)[0]
            self._qos2.discard(packet_id)
            self._send(packet(0x70, struct.pack("!H", packet_id)))

    def close(self) -> None:
        if self._socket is None:
            return
        try:
            self._send(packet(0xE0, b""))
        except (OSError, MqttError):
            pass
        finally:
            self._socket.close()
            self._socket = None

    # MARK: Pakete

    def _send(self, data: bytes) -> None:
        if self._socket is None:
            raise MqttError("Nicht verbunden.")
        try:
            with self._send_lock:
                self._socket.sendall(data)
        except OSError as error:
            raise MqttError(f"Senden fehlgeschlagen: {error}") from None

    def _read_exact(self, count: int) -> bytes:
        assert self._socket is not None
        data = bytearray()
        while len(data) < count:
            try:
                chunk = self._socket.recv(count - len(data))
            except (TimeoutError, socket.timeout):
                raise MqttError("Broker antwortet nicht (Zeitüberschreitung).") from None
            except OSError as error:
                raise MqttError(f"Verbindung abgebrochen: {error}") from None
            if not chunk:
                raise MqttError("Broker hat die Verbindung getrennt (Zugangsdaten/Rechte prüfen).")
            data.extend(chunk)
        return bytes(data)

    def _read_packet(self) -> tuple[int, bytes]:
        header = self._read_exact(1)[0]
        length, multiplier = 0, 1
        for _ in range(4):
            digit = self._read_exact(1)[0]
            length += (digit & 0x7F) * multiplier
            if digit & 0x80 == 0:
                break
            multiplier *= 128
        else:
            raise MqttError("Ungültige Paketlänge.")
        return header, self._read_exact(length) if length else b""


def publish_once(topic: str, payload: bytes | str, **connection: object) -> None:
    """Verbinden, mit QoS 1 senden, trennen."""
    with MqttConnection(**connection) as client:  # type: ignore[arg-type]
        client.publish(topic, payload, qos=1)
