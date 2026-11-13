"""Eingebauter MQTT-Broker (3.1.1) – ersetzt Mosquitto für den Betrieb auf dem Mac.

Nimmt nur das an, was FE2 mit dem MQTT-Plugin tut: anmelden und auf
`{Präfix}/{organisation}/alarm` senden (QoS 0, 1 oder 2). Anmeldung: Benutzer =
Kennung der Organisation, Passwort = MQTT-Passwort der Organisation. Eine
Organisation darf nur auf ihr eigenes Topic senden (wie die ACL bei Mosquitto).
Abonnieren wird abgelehnt (SUBACK 0x80) – Empfänger ist nur das Backend selbst.
"""

from __future__ import annotations

import logging
import socket
import ssl
import struct
import threading
import time
from typing import Any, Callable, Optional

from .ingest import AlarmIngest, IngestResult
from .organisations import Organisations
from .store import iso, utc_now

log = logging.getLogger("elrd.broker")


class ProtocolError(Exception):
    pass


def encode_length(length: int) -> bytes:
    out = bytearray()
    while True:
        digit, length = length % 128, length // 128
        out.append(digit | (0x80 if length else 0))
        if not length:
            return bytes(out)


def packet(header: int, body: bytes = b"") -> bytes:
    return bytes([header]) + encode_length(len(body)) + body


class _Reader:
    """Liest Pakete von einem Socket."""

    def __init__(self, connection: socket.socket) -> None:
        self.connection = connection

    def exact(self, count: int) -> bytes:
        data = bytearray()
        while len(data) < count:
            chunk = self.connection.recv(count - len(data))
            if not chunk:
                raise ConnectionError("getrennt")
            data.extend(chunk)
        return bytes(data)

    def packet(self) -> tuple[int, bytes]:
        header = self.exact(1)[0]
        length, multiplier = 0, 1
        for _ in range(4):
            digit = self.exact(1)[0]
            length += (digit & 0x7F) * multiplier
            if not digit & 0x80:
                break
            multiplier *= 128
        else:
            raise ProtocolError("Ungültige Paketlänge.")
        if length > 1024 * 1024:
            raise ProtocolError("Paket zu groß.")
        return header, self.exact(length) if length else b""


def _string(body: bytes, offset: int) -> tuple[str, int]:
    if offset + 2 > len(body):
        raise ProtocolError("Text fehlt.")
    length = struct.unpack_from("!H", body, offset)[0]
    end = offset + 2 + length
    if end > len(body):
        raise ProtocolError("Text zu kurz.")
    return body[offset + 2:end].decode("utf-8", errors="replace"), end


class Broker:
    def __init__(
        self,
        ingest: AlarmIngest,
        organisations: Organisations,
        prefix: str = "elrd",
        host: str = "0.0.0.0",
        port: int = 1883,
        tls_port: Optional[int] = None,
        certfile: Optional[str] = None,
        keyfile: Optional[str] = None,
        on_result: Optional[Callable[[str, IngestResult], None]] = None,
    ) -> None:
        self.ingest = ingest
        self.organisations = organisations
        self.prefix = prefix.strip().strip("/")
        self.host = host
        self.port = port
        self.tls_port = tls_port
        self.certfile = certfile
        self.keyfile = keyfile
        self.on_result = on_result
        self._sockets: list[socket.socket] = []
        self._stop = threading.Event()
        self._lock = threading.Lock()
        self.clients: dict[int, dict[str, Any]] = {}
        self.messages_received = 0
        self.last_message_at: Optional[str] = None
        self.started_at: Optional[str] = None
        self.last_error: Optional[str] = None

    # MARK: Start und Stopp

    def start(self) -> None:
        self._listen(self.port, None)
        if self.tls_port:
            if not (self.certfile and self.keyfile):
                raise ValueError("Für MQTT mit TLS werden Zertifikat und Schlüssel gebraucht (broker.zertifikat / broker.schluessel).")
            context = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
            context.load_cert_chain(self.certfile, self.keyfile)
            self._listen(self.tls_port, context)
        self.started_at = iso(utc_now())

    def _listen(self, port: int, context: Optional[ssl.SSLContext]) -> None:
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind((self.host, port))
        server.listen(32)
        server.settimeout(1)
        if port == 0:  # Tests: freier Port
            self.port = server.getsockname()[1]
        self._sockets.append(server)
        threading.Thread(target=self._accept_loop, args=(server, context), name=f"mqtt-{port}", daemon=True).start()

    def stop(self) -> None:
        self._stop.set()
        for server in self._sockets:
            server.close()

    @property
    def listening(self) -> bool:
        return bool(self._sockets) and not self._stop.is_set()

    def topic(self, organisation_id: str) -> str:
        return f"{self.prefix}/{organisation_id}/alarm"

    # MARK: Verbindungen

    def _accept_loop(self, server: socket.socket, context: Optional[ssl.SSLContext]) -> None:
        while not self._stop.is_set():
            try:
                connection, address = server.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            threading.Thread(target=self._serve, args=(connection, address, context), daemon=True).start()

    def _serve(self, connection: socket.socket, address: tuple, context: Optional[ssl.SSLContext]) -> None:
        client_key = id(connection)
        username = "?"
        try:
            connection.settimeout(10)
            if context is not None:
                connection = context.wrap_socket(connection, server_side=True)
            reader = _Reader(connection)
            header, body = reader.packet()
            if header & 0xF0 != 0x10:
                return
            username, keep_alive, code = self._connect(body)
            connection.sendall(packet(0x20, bytes([0, code])))
            if code != 0:
                log.warning("MQTT-Anmeldung abgelehnt: Benutzer „%s“ von %s", username, address[0])
                return
            with self._lock:
                self.clients[client_key] = {"user": username, "address": address[0], "since": iso(utc_now())}
            log.info("MQTT: „%s“ verbunden (%s)", username, address[0])
            connection.settimeout(keep_alive * 1.5 if keep_alive else None)
            self._session(connection, reader, username)
        except (ConnectionError, socket.timeout, ssl.SSLError, OSError):
            pass
        except ProtocolError as error:
            log.warning("MQTT-Protokollfehler von %s: %s", address[0], error)
        finally:
            with self._lock:
                if self.clients.pop(client_key, None):
                    log.info("MQTT: „%s“ getrennt", username)
            try:
                connection.close()
            except OSError:
                pass

    def _connect(self, body: bytes) -> tuple[str, int, int]:
        """Liest CONNECT; liefert (Benutzer, Keep-Alive, Rückgabecode)."""
        protocol, offset = _string(body, 0)
        level = body[offset]
        flags = body[offset + 1]
        keep_alive = struct.unpack_from("!H", body, offset + 2)[0]
        offset += 4
        if (protocol, level) not in (("MQTT", 4), ("MQIsdp", 3)):
            return "?", keep_alive, 1  # nicht unterstützte Protokollversion
        _, offset = _string(body, offset)  # Client-ID
        if flags & 0x04:  # Last Will: Topic und Nachricht überspringen
            _, offset = _string(body, offset)
            _, offset = _string(body, offset)
        username = password = ""
        if flags & 0x80:
            username, offset = _string(body, offset)
        if flags & 0x40:
            password, offset = _string(body, offset)
        if not username or not self.organisations.check_mqtt(username, password):
            return username or "?", keep_alive, 5
        return username, keep_alive, 0

    def _session(self, connection: socket.socket, reader: _Reader, username: str) -> None:
        pending_qos2: set[int] = set()
        while not self._stop.is_set():
            header, body = reader.packet()
            kind = header & 0xF0
            if kind == 0x30:  # PUBLISH
                qos = (header >> 1) & 0x03
                topic, offset = _string(body, 0)
                packet_id = 0
                if qos:
                    packet_id = struct.unpack_from("!H", body, offset)[0]
                    offset += 2
                payload = body[offset:]
                if qos == 2:
                    if packet_id not in pending_qos2:
                        pending_qos2.add(packet_id)
                        self._receive(username, topic, payload)
                    connection.sendall(packet(0x50, struct.pack("!H", packet_id)))
                else:
                    self._receive(username, topic, payload)
                    if qos == 1:
                        connection.sendall(packet(0x40, struct.pack("!H", packet_id)))
            elif kind == 0x60:  # PUBREL
                packet_id = struct.unpack_from("!H", body, 0)[0]
                pending_qos2.discard(packet_id)
                connection.sendall(packet(0x70, struct.pack("!H", packet_id)))
            elif kind == 0x80:  # SUBSCRIBE → ablehnen
                packet_id = struct.unpack_from("!H", body, 0)[0]
                offset, codes = 2, bytearray()
                while offset < len(body):
                    _, offset = _string(body, offset)
                    offset += 1
                    codes.append(0x80)
                connection.sendall(packet(0x90, struct.pack("!H", packet_id) + bytes(codes)))
            elif kind == 0xA0:  # UNSUBSCRIBE
                connection.sendall(packet(0xB0, body[:2]))
            elif kind == 0xC0:  # PINGREQ
                connection.sendall(packet(0xD0))
            elif kind == 0xE0:  # DISCONNECT
                return

    def _receive(self, username: str, topic: str, payload: bytes) -> None:
        expected = self.topic(username)
        if topic != expected:
            # Wie Mosquitto mit ACL: still verwerfen, nur protokollieren.
            log.warning("MQTT: „%s“ darf nicht auf „%s“ senden (erlaubt: %s)", username, topic, expected)
            return
        self.deliver(username, payload)

    def deliver(self, organisation_id: str, payload: bytes, source: str = "mqtt") -> IngestResult:
        """Wie eine empfangene Nachricht verarbeiten (auch für „über den Broker“ der Debug-Seite)."""
        with self._lock:
            self.messages_received += 1
            self.last_message_at = iso(utc_now())
        result = self.ingest.ingest(organisation_id, payload, source=source)
        if self.on_result:
            self.on_result(organisation_id, result)
        return result

    def status(self) -> dict[str, Any]:
        with self._lock:
            clients = [dict(client) for client in self.clients.values()]
            return {
                "listening": self.listening,
                "port": self.port,
                "tlsPort": self.tls_port,
                "clients": clients,
                "messagesReceived": self.messages_received,
                "lastMessageAt": self.last_message_at,
                "since": self.started_at,
            }


def wait_until(condition: Callable[[], bool], timeout: float = 5) -> bool:
    """Hilfe für Tests: warten, bis eine Bedingung erfüllt ist."""
    end = time.time() + timeout
    while time.time() < end:
        if condition():
            return True
        time.sleep(0.02)
    return False
