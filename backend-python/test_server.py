"""Tests für das Python-Backend (Python 3.9+, nur Standardbibliothek).

    python3 -m unittest -v test_server            # im Ordner backend-python
Mit externem Broker (z. B. Mosquitto) zusätzlich die Abholung von dort:
    ELRD_TEST_MQTT_BRIDGE=localhost:1883:elrd-backend:entwicklung-backend python3 -m unittest -v test_server
"""

from __future__ import annotations

import json
import os
import socket
import struct
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from datetime import timedelta
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "tools" / "alamos"))
sys.path.insert(0, str(HERE))

import fe2_format as fe2  # noqa: E402
from mqtt_client import MqttConnection, MqttError, publish_once  # noqa: E402

from elrd.bridge import ExternalBridge  # noqa: E402
from elrd.broker import Broker, packet, wait_until  # noqa: E402
from elrd.ingest import AlarmIngest  # noqa: E402
from elrd.organisations import Organisations, hash_api_key, verify_password  # noqa: E402
from elrd.store import Store, iso, parse_iso, utc_now  # noqa: E402
from elrd.web import Backend, make_server  # noqa: E402

ADMIN = "test-admin-schluessel-123"


class TempDir:
    def __init__(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.path = Path(self.directory.name)


class StoreAndIngestTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = TempDir()
        self.store = Store(self.temp.path)
        self.ingest = AlarmIngest(self.store)

    def tearDown(self) -> None:
        self.temp.directory.cleanup()

    def send(self, envelope: object, organisation: str = "org") -> object:
        return self.ingest.ingest(organisation, json.dumps(envelope).encode(), source="mqtt")

    def test_create_update_unchanged_close_reopen(self) -> None:
        alarm = fe2.load_sample("vu", "4711")
        self.assertEqual(self.send(alarm).outcome, "Created")
        self.assertEqual(self.send(alarm).outcome, "Unchanged")
        changed = fe2.apply_change(alarm, "stichwort")
        result = self.send(changed)
        self.assertEqual((result.outcome, result.alarm["revision"], result.alarm["data"]["keyword"]), ("Updated", 2, "RD 3"))
        self.assertTrue(result.alarm["isTest"])
        closed = self.send(fe2.close_message("4711"))
        self.assertEqual(closed.outcome, "Closed")
        self.assertIsNotNone(closed.alarm["closedAt"])
        self.assertEqual(self.send(fe2.close_message("4711")).outcome, "Unchanged")
        self.assertIsNone(self.send(changed).alarm["closedAt"], "neue Daten öffnen wieder")
        self.assertEqual(self.send(alarm, organisation="andere").outcome, "Created", "eigene Nummern je Organisation")

    def test_special_inputs(self) -> None:
        self.assertEqual(self.send({"type": "STATUS", "data": {"status": "3"}}).outcome, "Ignored")
        self.assertEqual(self.ingest.ingest("org", b"U2FsdGVkX1+", "mqtt").outcome, "Rejected")
        self.assertEqual(self.send({"externalId": 99, "keyword": "RD 1"}).alarm["externalId"], "99", "ohne Umschlag, Zahl")
        wrapped = json.dumps(json.dumps(fe2.load_sample("intern", "55"))).encode()
        self.assertEqual(self.ingest.ingest("org", wrapped, "mqtt").outcome, "Created", "JSON als Text")
        without_number = self.send({"type": "ALARM", "data": {"keyword": "RD 1"}})
        self.assertTrue(without_number.alarm["externalId"].startswith("elrd-"))
        self.assertEqual(self.ingest.ingest("org", b"x" * (512 * 1024 + 1), "mqtt").outcome, "Rejected")

    def test_store_survives_restart(self) -> None:
        self.send(fe2.load_sample("bus", "1"))
        again = Store(self.temp.path)
        self.assertEqual(again.read(lambda s: s["alarms"][0]["data"]["keyword"]), "RD 4")

    def test_iso_dates(self) -> None:
        moment = utc_now()
        text = iso(moment)
        self.assertTrue(text.endswith("Z") and len(text) == 24)
        self.assertAlmostEqual(parse_iso(text).timestamp(), moment.timestamp(), delta=0.001)
        self.assertIsNotNone(parse_iso("2026-11-12T20:15:00+01:00"))
        self.assertIsNotNone(parse_iso("2026-11-12T20:15:00.1Z"))
        self.assertIsNone(parse_iso("gestern"))


class OrganisationTests(unittest.TestCase):
    def test_keys_and_passwords(self) -> None:
        temp = TempDir()
        organisations = Organisations(Store(temp.path))
        organisation, key, password = organisations.create("BRK-SW", "BRK Schweinfurt")
        self.assertEqual(organisation["id"], "brk-sw")
        self.assertEqual(organisations.authenticate(key)["id"], "brk-sw")
        self.assertIsNone(organisations.authenticate(key + "x"))
        self.assertTrue(organisations.check_mqtt("brk-sw", password))
        self.assertFalse(organisations.check_mqtt("brk-sw", "falsch"))
        self.assertFalse(organisations.check_mqtt("unbekannt", password))
        stored = json.loads((temp.path / "store.json").read_text())
        self.assertNotIn(key, json.dumps(stored))
        self.assertNotIn(password, json.dumps(stored))
        # Gleicher Hash wie das .NET-Backend (store.json austauschbar).
        self.assertEqual(hash_api_key("elrd_test"), "C15cMFyEfahthYPMwewQyZaL/GUpCsgAovRcA49ekfY=")
        renewed = organisations.renew_key("brk-sw")
        self.assertIsNone(organisations.authenticate(key))
        self.assertIsNotNone(organisations.authenticate(renewed))
        new_password = organisations.renew_mqtt_password("brk-sw")
        self.assertTrue(verify_password(new_password, organisations.get("brk-sw")["mqttPasswordHash"]))
        for bad in ("x", "ä/b"):
            with self.assertRaises(ValueError):
                organisations.create(bad, "n")
        with self.assertRaises(ValueError):
            organisations.create("brk-sw", "doppelt")
        self.assertTrue(organisations.delete("brk-sw"))
        temp.directory.cleanup()


class ServerTests(unittest.TestCase):
    """Backend mit eingebautem Broker und HTTP auf freien Ports."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.temp = TempDir()
        store = Store(cls.temp.path)
        cls.backend = Backend(store, admin_key=ADMIN, debug=True, web_root=HERE.parent / "backend" / "src" / "ELRD.Backend" / "wwwroot")
        _, cls.key, _ = cls.backend.organisations.create("test-rd", "Test RD", mqtt_password="fe2-passwort")
        cls.backend.organisations.create("andere", "Andere", mqtt_password="anderes-passwort")
        cls.backend.broker = Broker(cls.backend.ingest, cls.backend.organisations, host="127.0.0.1", port=0)
        cls.backend.broker.start()
        cls.server = make_server(cls.backend, "127.0.0.1", 0)
        cls.base = f"http://127.0.0.1:{cls.server.server_address[1]}"
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls) -> None:
        cls.server.shutdown()
        cls.server.server_close()
        cls.backend.broker.stop()
        cls.temp.directory.cleanup()

    def request(self, method: str, path: str, body: object = None, key: str = None, admin: bool = False) -> tuple:
        headers = {"Content-Type": "application/json"}
        if key:
            headers["Authorization"] = f"Bearer {key}"
        if admin:
            headers["X-Admin-Key"] = ADMIN
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(self.base + path, data=data, method=method, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=5) as response:
                raw = response.read()
                return response.status, json.loads(raw) if raw and response.headers.get_content_type() == "application/json" else raw
        except urllib.error.HTTPError as error:
            raw = error.read()
            return error.code, json.loads(raw) if raw else None

    def publish(self, payload: object, user: str = "test-rd", password: str = "fe2-passwort", topic: str = None) -> None:
        publish_once(topic or f"elrd/{user}/alarm", json.dumps(payload), host="127.0.0.1", port=self.backend.broker.port,
                     username=user, password=password)

    def alarms(self, query: str = "") -> list:
        status, body = self.request("GET", "/api/v1/alarms" + query, key=self.key)
        self.assertEqual(status, 200)
        return body["alarms"]

    def find(self, number: str) -> dict:
        return next((a for a in self.alarms() if a["externalId"] == number), None)

    def test_fe2_over_builtin_broker(self) -> None:
        alarm = fe2.load_sample("vu", "B-1")
        self.publish(alarm)
        self.assertTrue(wait_until(lambda: self.find("B-1") is not None))
        self.publish(fe2.apply_change(alarm, "fahrzeug"))
        self.assertTrue(wait_until(lambda: self.find("B-1")["revision"] == 2))
        found = self.find("B-1")
        self.assertEqual(found["source"], "mqtt")
        self.assertNotIn("organisationId", found)
        self.assertNotIn("closedAt", found, "Nullwerte weglassen wie .NET")

    def test_broker_rejects_wrong_password_and_foreign_topic(self) -> None:
        with self.assertRaises(MqttError):
            self.publish(fe2.load_sample("vu", "B-2"), password="falsch")
        # Organisation „andere“ schreibt auf das Topic von test-rd → verworfen.
        self.publish(fe2.load_sample("vu", "B-3"), user="andere", password="anderes-passwort", topic="elrd/test-rd/alarm")
        self.publish(fe2.load_sample("vu", "B-4"))
        self.assertTrue(wait_until(lambda: self.find("B-4") is not None))
        self.assertIsNone(self.find("B-3"))
        with MqttConnection("127.0.0.1", self.backend.broker.port, "test-rd", "fe2-passwort") as client:
            with self.assertRaises(MqttError):
                client.subscribe("elrd/#")

    def test_qos2_delivered_once(self) -> None:
        payload = json.dumps(fe2.load_sample("intern", "Q-2")).encode()
        with socket.create_connection(("127.0.0.1", self.backend.broker.port), timeout=5) as raw:
            def string(text: str) -> bytes:
                return struct.pack("!H", len(text)) + text.encode()
            raw.sendall(packet(0x10, string("MQTT") + bytes([4, 0xC2]) + struct.pack("!H", 30) + string("q2") + string("test-rd") + string("fe2-passwort")))
            self.assertEqual(raw.recv(4), b"\x20\x02\x00\x00")
            publish = packet(0x34, string("elrd/test-rd/alarm") + struct.pack("!H", 7) + payload)
            raw.sendall(publish)
            self.assertEqual(raw.recv(4), b"\x50\x02\x00\x07")  # PUBREC
            raw.sendall(bytes([0x3C]) + publish[1:])  # Wiederholung mit DUP
            self.assertEqual(raw.recv(4), b"\x50\x02\x00\x07")
            raw.sendall(packet(0x62, struct.pack("!H", 7)))
            self.assertEqual(raw.recv(4), b"\x70\x02\x00\x07")  # PUBCOMP
            raw.sendall(packet(0xC0))
            self.assertEqual(raw.recv(2), b"\xd0\x00")
        self.assertTrue(wait_until(lambda: self.find("Q-2") is not None))
        self.assertEqual(self.find("Q-2")["revision"], 1)

    def test_app_api(self) -> None:
        self.assertEqual(self.request("GET", "/api/v1/alarms")[0], 401)
        self.assertEqual(self.request("GET", "/api/v1/alarms", key="falsch")[0], 401)
        status, ping = self.request("GET", "/api/v1/ping", key=self.key)
        self.assertEqual((status, ping["organisationId"], ping["retentionHours"]), (200, "test-rd", 24))
        self.request("POST", "/admin/api/debug/test-rd/alarms", {"sampleId": "bus"}, admin=True)
        status, body = self.request("GET", "/api/v1/alarms", key=self.key)
        server_time = body["serverTime"]
        self.assertTrue(server_time.endswith("Z") and "." in server_time)
        self.assertEqual(self.alarms("?since=" + server_time), [])
        bus = next(a for a in body["alarms"] if a["data"]["keyword"] == "RD 4")
        status, delivery = self.request("POST", f"/admin/api/debug/test-rd/alarms/{bus['id']}/simulate", {"change": "patient", "via": "direct"}, admin=True)
        self.assertEqual((status, delivery["outcome"]), (200, "Updated"))
        changed = self.alarms("?since=" + server_time)
        self.assertEqual([a["id"] for a in changed], [bus["id"]])
        self.assertEqual(len(changed[0]["data"]["patient"]), 4)
        self.assertEqual(self.request("GET", f"/api/v1/alarms/{bus['id']}", key=self.key)[0], 200)
        self.assertEqual(self.request("GET", "/api/v1/alarms/00000000-0000-0000-0000-000000000000", key=self.key)[0], 404)
        self.request("POST", f"/admin/api/debug/test-rd/alarms/{bus['id']}/simulate", {"change": "close"}, admin=True)
        self.assertNotIn(bus["id"], [a["id"] for a in self.alarms("?includeClosed=false")])
        # Fremde Organisation sieht nichts davon.
        _, other_key, _ = self.backend.organisations.create("dritte", "Dritte")
        status, body = self.request("GET", "/api/v1/alarms", key=other_key)
        self.assertEqual(body["alarms"], [])

    def test_admin_and_debug(self) -> None:
        self.assertEqual(self.request("GET", "/admin/api/status")[0], 401)
        status, body = self.request("GET", "/admin/api/status", admin=True)
        self.assertEqual(status, 200)
        self.assertTrue(body["mqtt"]["enabled"] and body["mqtt"]["connected"] and body["builtInBroker"])
        status, created = self.request("POST", "/admin/api/organisations", {"id": "neu-org", "name": "Neu"}, admin=True)
        self.assertEqual(status, 200)
        self.assertTrue(created["apiKey"].startswith("elrd_") and created["mqttPassword"])
        self.assertEqual(created["organisation"]["mqttUser"], "neu-org")
        self.assertEqual(self.request("POST", "/admin/api/organisations", {"id": "neu-org", "name": "x"}, admin=True)[0], 400)
        status, renewed = self.request("POST", "/admin/api/organisations/neu-org/mqtt-password", admin=True)
        self.publish(fe2.load_sample("vu", "N-1"), user="neu-org", password=renewed["mqttPassword"])
        self.assertEqual(self.request("DELETE", "/admin/api/organisations/neu-org", admin=True)[0], 204)
        status, info = self.request("GET", "/admin/api/debug/info", admin=True)
        self.assertEqual([s["id"] for s in info["samples"]], ["bus", "intern", "pflegeheim", "vu"])
        self.assertIn("close", [c["id"] for c in info["changes"]])
        status, delivery = self.request("POST", "/admin/api/debug/test-rd/alarms", {"sampleId": "intern", "via": "mqtt"}, admin=True)
        self.assertEqual((status, delivery["via"], delivery["outcome"]), (200, "mqtt", "Created"))
        self.assertEqual(self.request("POST", "/admin/api/debug/test-rd/raw", {"json": "{kaputt"}, admin=True)[0], 400)
        status, raw = self.request("POST", "/admin/api/debug/test-rd/raw", {"json": json.dumps(fe2.load_sample("vu", "R-1"))}, admin=True)
        self.assertEqual(raw["outcome"], "Created")
        self.assertEqual(self.request("POST", "/admin/api/debug/gibtsnicht/alarms", {}, admin=True)[0], 404)
        status, listed = self.request("GET", "/admin/api/debug/test-rd/alarms", admin=True)
        self.assertTrue(all(a["organisationId"] == "test-rd" for a in listed))

    def test_web_page_and_health(self) -> None:
        status, page = self.request("GET", "/")
        self.assertEqual(status, 200)
        self.assertIn(b"ELRD-Backend", page)
        self.assertEqual(self.request("GET", "/app.js")[0], 200)
        self.assertEqual(self.request("GET", "/../elrd_server.py")[0], 404)
        status, health = self.request("GET", "/health")
        self.assertEqual(health["mqtt"], "connected")

    def test_https_on_http_port(self) -> None:
        """App mit https:// auf dem HTTP-Port: Hinweis im Log statt Absturz im Logging."""
        client_hello = b"\x16\x03\x01\x02\x00\x01\x00\x01\xfc\x03\x03" + bytes(32) + b"\x00\x20"
        with self.assertLogs("elrd.web", level="WARNING") as logs:
            with socket.create_connection(("127.0.0.1", self.server.server_address[1]), timeout=5) as raw:
                raw.sendall(client_hello)
                raw.shutdown(socket.SHUT_WR)
                raw.recv(64)  # Fehlerantwort (Python 3.9: ohne Statuszeile) oder geschlossen
        self.assertTrue(any("HTTPS-Anfrage" in line for line in logs.output), logs.output)
        self.assertEqual(self.request("GET", "/health")[0], 200)

    def test_retention(self) -> None:
        old = iso(utc_now() - timedelta(hours=30))
        self.backend.store.write(lambda s: s["alarms"].append({"id": "x", "organisationId": "test-rd", "externalId": "ALT", "revision": 1,
                                                                "receivedAt": old, "updatedAt": old, "source": "mqtt", "isTest": True, "data": {}}))
        self.assertGreaterEqual(self.backend.purge(), 1)
        self.assertFalse(any(a["externalId"] == "ALT" for a in self.backend.store.read(lambda s: s["alarms"])))


@unittest.skipUnless(os.environ.get("ELRD_TEST_MQTT_BRIDGE"), "ELRD_TEST_MQTT_BRIDGE nicht gesetzt")
class ExternalBrokerTests(unittest.TestCase):
    def test_bridge_receives_from_external_broker(self) -> None:
        host, port, user, password = os.environ["ELRD_TEST_MQTT_BRIDGE"].split(":")
        temp = TempDir()
        store = Store(temp.path)
        organisations = Organisations(store)
        organisations.create("test-rd", "Test")
        bridge = ExternalBridge({"host": host, "port": int(port), "tls": False, "benutzer": user, "passwort": password,
                                 "client_id": "elrd-py-test"}, AlarmIngest(store), organisations, "elrd")
        bridge.start()
        try:
            self.assertTrue(wait_until(lambda: bridge.connected, 10), bridge.last_error)
            publish_once("elrd/test-rd/alarm", json.dumps(fe2.load_sample("vu", "X-1")), host=host, port=int(port), username=user, password=password)
            self.assertTrue(wait_until(lambda: store.read(lambda s: len(s["alarms"])) == 1, 10))
            bridge.publish("test-rd", json.dumps(fe2.load_sample("vu", "X-2")).encode())
            self.assertTrue(wait_until(lambda: store.read(lambda s: len(s["alarms"])) == 2, 10))
        finally:
            bridge.stop()
            temp.directory.cleanup()


if __name__ == "__main__":
    unittest.main()
