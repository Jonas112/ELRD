"""Tests für das Python-Backend (Python 3.9+, nur Standardbibliothek).

    python3 -m unittest -v test_server            # im Ordner backend-python
Mit externem Broker (z. B. Mosquitto) zusätzlich die Abholung von dort:
    ELRD_TEST_MQTT_BRIDGE=localhost:1883:elrd-backend:entwicklung-backend python3 -m unittest -v test_server
"""

from __future__ import annotations

import base64
import json
import os
import shutil
import subprocess
import socket
import struct
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from datetime import timedelta
from http.server import BaseHTTPRequestHandler, HTTPServer
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
from elrd import push as apns  # noqa: E402
from elrd.web import Backend, make_server  # noqa: E402

ADMIN = "test-admin-schluessel-123"


class TempDir:
    def __init__(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.path = Path(self.directory.name)

    def __enter__(self) -> Path:
        return self.path

    def __exit__(self, *exc: object) -> None:
        self.directory.cleanup()


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




def pkcs8_pem(private: int) -> str:
    """Schlüsseldatei wie von Apple (.p8, PKCS#8, P-256) – ohne öffentlichen Teil."""
    der = (bytes.fromhex("3041020100301306072a8648ce3d020106082a8648ce3d030107042730250201010420")
           + private.to_bytes(32, "big"))
    body = base64.b64encode(der).decode()
    return "-----BEGIN PRIVATE KEY-----\n" + body + "\n-----END PRIVATE KEY-----\n"


class PushTests(unittest.TestCase):
    """Schritt 144: Push-Mitteilungen über APNs (ohne echten Versand)."""

    PRIVATE = 0x1F2E3D4C5B6A79880F1E2D3C4B5A69788796A5B4C3D2E1F00112233445566778
    TOKEN = "ab" * 32

    def test_signature_and_token(self) -> None:
        private = apns.load_private_key(pkcs8_pem(self.PRIVATE))
        self.assertEqual(private, self.PRIVATE)
        public = apns.public_key(private)
        signature = apns.sign(b"ELRD", private)
        self.assertTrue(apns.verify(b"ELRD", signature, public))
        self.assertFalse(apns.verify(b"ELRD!", signature, public))
        token = apns.make_token("TEAM123456", "KEY1234567", private, issued_at=1_700_000_000)
        header, claims, signed = token.split(".")
        pad = lambda text: text + "=" * (-len(text) % 4)  # noqa: E731
        self.assertEqual(json.loads(base64.urlsafe_b64decode(pad(header))), {"alg": "ES256", "kid": "KEY1234567"})
        self.assertEqual(json.loads(base64.urlsafe_b64decode(pad(claims))), {"iss": "TEAM123456", "iat": 1_700_000_000})
        self.assertTrue(apns.verify(f"{header}.{claims}".encode(), base64.urlsafe_b64decode(pad(signed)), public))
        with self.assertRaises(ValueError):
            apns.load_private_key("-----BEGIN PRIVATE KEY-----\nkaputt\n-----END PRIVATE KEY-----")

    @unittest.skipUnless(shutil.which("openssl"), "openssl fehlt")
    def test_signature_matches_openssl(self) -> None:
        """Gegenprobe mit OpenSSL: gleicher öffentlicher Schlüssel, Signatur gültig."""
        with TempDir() as directory:
            key = directory / "key.p8"
            key.write_text(pkcs8_pem(self.PRIVATE))
            public_der = subprocess.run(["openssl", "pkey", "-in", str(key), "-pubout", "-outform", "DER"],
                                        capture_output=True, check=True).stdout
            x, y = apns.public_key(self.PRIVATE)
            self.assertEqual(public_der[-65:], b"\x04" + x.to_bytes(32, "big") + y.to_bytes(32, "big"))
            signature = apns.sign(b"Nachricht", self.PRIVATE)
            r, s = (int.from_bytes(signature[:32], "big"), int.from_bytes(signature[32:], "big"))

            def integer(value: int) -> bytes:
                raw = value.to_bytes(33, "big").lstrip(b"\x00") or b"\x00"
                raw = b"\x00" + raw if raw[0] & 0x80 else raw
                return bytes([0x02, len(raw)]) + raw
            body = integer(r) + integer(s)
            (directory / "sig.der").write_bytes(bytes([0x30, len(body)]) + body)
            (directory / "pub.der").write_bytes(public_der)
            (directory / "msg").write_bytes(b"Nachricht")
            result = subprocess.run(["openssl", "dgst", "-sha256", "-verify", str(directory / "pub.der"), "-keyform", "DER",
                                     "-signature", str(directory / "sig.der"), str(directory / "msg")], capture_output=True, text=True)
            self.assertIn("Verified OK", result.stdout, result.stderr)

    def make_backend(self, directory: Path, replies: list) -> tuple:
        (directory / "AuthKey.p8").write_text(pkcs8_pem(self.PRIVATE))
        calls = []

        def sender(url: str, headers: dict, body: bytes) -> tuple:
            calls.append((url, headers, json.loads(body)))
            return replies.pop(0) if replies else (200, "")

        store = Store(directory)
        settings = {"eingeschaltet": True, "team_id": "TEAM123456", "key_id": "KEY1234567", "schluessel_datei": "AuthKey.p8"}
        service = apns.PushService(store, settings, sender=sender, base_dir=directory)
        backend = Backend(store, admin_key=ADMIN, push=service)
        _, key, _ = backend.organisations.create("test-rd", "Test RD")
        return backend, service, calls, key

    def test_new_alarm_is_pushed_without_patient_data(self) -> None:
        with TempDir() as directory:
            backend, service, calls, _ = self.make_backend(directory, [])
            self.assertTrue(service.configured)
            service.register("test-rd", self.TOKEN.upper(), "sandbox")
            service.register("test-rd", self.TOKEN, "sandbox")  # doppelt → einmal
            self.assertEqual(len(service.devices("test-rd")), 1)
            with self.assertRaises(ValueError):
                service.register("test-rd", "kein-token", "sandbox")

            alarm = fe2.load_sample("vu", "P-1")
            alarm["data"]["patient"] = [{"name": "Erika Muster", "remark": "Schock"}]
            backend.ingest.ingest("test-rd", json.dumps(alarm).encode(), source="mqtt")
            self.assertTrue(wait_until(lambda: len(calls) == 1))
            url, headers, payload = calls[0]
            self.assertEqual(url, f"https://api.sandbox.push.apple.com/3/device/{self.TOKEN}")
            self.assertEqual(headers["apns-topic"], "ELRD.App")
            self.assertEqual(headers["apns-push-type"], "alert")
            self.assertTrue(headers["authorization"].startswith("bearer ey"))
            stored = backend.store.read(lambda s: s["alarms"][0])
            self.assertEqual(headers["apns-collapse-id"], f"alamos-{stored['id']}")
            self.assertEqual(payload["elrd"]["alarmId"], stored["id"])
            self.assertNotIn("Erika", json.dumps(payload, ensure_ascii=False))
            self.assertIn(alarm["data"]["keyword"], payload["aps"]["alert"]["body"])

            # Aktualisierung → keine weitere Mitteilung.
            alarm["data"]["message"] = ["geändert"]
            backend.ingest.ingest("test-rd", json.dumps(alarm).encode(), source="mqtt")
            threading.Event().wait(0.2)
            self.assertEqual(len(calls), 1)

    def test_rejected_device_is_removed(self) -> None:
        with TempDir() as directory:
            _, service, calls, _ = self.make_backend(directory, [(410, '{"reason":"Unregistered"}')])
            service.register("test-rd", self.TOKEN, "production")
            result = service.send("test-rd", {"aps": {"alert": "x"}})
            self.assertEqual((result["sent"], result["failed"]), (0, 1))
            self.assertEqual(result["results"][0]["reason"], "Unregistered")
            self.assertTrue(calls[0][0].startswith("https://api.push.apple.com/"))
            self.assertEqual(service.devices("test-rd"), [])

    def test_device_api_and_test_push(self) -> None:
        with TempDir() as directory:
            backend, service, calls, key = self.make_backend(directory, [])
            server = make_server(backend, "127.0.0.1", 0)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            base = f"http://127.0.0.1:{server.server_address[1]}"
            try:
                def call(method: str, path: str, body: object = None, admin: bool = False) -> tuple:
                    headers = {"Content-Type": "application/json"}
                    headers.update({"X-Admin-Key": ADMIN} if admin else {"Authorization": f"Bearer {key}"})
                    data = json.dumps(body).encode() if body is not None else None
                    request = urllib.request.Request(base + path, data=data, method=method, headers=headers)
                    try:
                        with urllib.request.urlopen(request, timeout=5) as response:
                            raw = response.read()
                            return response.status, json.loads(raw) if raw else None
                    except urllib.error.HTTPError as error:
                        return error.code, json.loads(error.read() or b"null")

                self.assertEqual(call("POST", "/admin/api/organisations/test-rd/push-test", admin=True)[0], 400, "noch kein Gerät")
                status, body = call("POST", "/api/v1/devices", {"token": self.TOKEN, "environment": "sandbox"})
                self.assertEqual((status, body), (200, {"registered": True, "pushEnabled": True}))
                self.assertEqual(call("POST", "/api/v1/devices", {"token": "xyz"})[0], 400)
                self.assertTrue(call("GET", "/api/v1/ping")[1]["pushEnabled"])
                status, result = call("POST", "/admin/api/organisations/test-rd/push-test", admin=True)
                self.assertEqual((status, result["sent"]), (200, 1))
                self.assertEqual(calls[-1][2]["elrd"]["kind"], "test")
                status, info = call("GET", "/admin/api/status", admin=True)
                self.assertEqual((info["push"]["configured"], info["push"]["devices"]), (True, 1))
                self.assertEqual(call("GET", "/admin/api/organisations", admin=True)[1][0]["devices"], 1)
                self.assertEqual(call("DELETE", f"/api/v1/devices/{self.TOKEN}")[0], 204)
                self.assertEqual(service.devices("test-rd"), [])
            finally:
                server.shutdown()
                server.server_close()

    def test_disabled_or_incomplete(self) -> None:
        with TempDir() as directory:
            store = Store(directory)
            self.assertFalse(apns.PushService(store).configured)
            broken = apns.PushService(store, {"eingeschaltet": True, "team_id": "T", "key_id": "K", "schluessel_datei": "fehlt.p8"},
                                      sender=lambda *a: (200, ""), base_dir=directory)
            self.assertFalse(broken.configured)
            self.assertIn("nicht gefunden", broken.last_error)

    @unittest.skipUnless(apns.curl_status()[0], "curl mit HTTP/2 fehlt")
    def test_curl_sender(self) -> None:
        """Versand über curl: Kopfzeilen und Inhalt kommen an (lokaler Server statt Apple)."""
        received = {}

        class Fake(BaseHTTPRequestHandler):
            def do_POST(self) -> None:  # noqa: N802
                received["path"] = self.path
                received["headers"] = dict(self.headers)
                received["body"] = self.rfile.read(int(self.headers.get("Content-Length") or 0))
                answer = b'{"reason":"BadDeviceToken"}'
                self.send_response(400)
                self.send_header("Content-Length", str(len(answer)))
                self.end_headers()
                self.wfile.write(answer)

            def log_message(self, *args: object) -> None:
                pass

        server = HTTPServer(("127.0.0.1", 0), Fake)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            url = f"http://127.0.0.1:{server.server_address[1]}/3/device/{self.TOKEN}"
            status, text = apns.send_with_curl(url, {"authorization": "bearer abc\"def", "apns-topic": "ELRD.App"}, b'{"aps":{}}')
            self.assertEqual(status, 400)
            self.assertIn("BadDeviceToken", text)
            self.assertEqual(received["path"], f"/3/device/{self.TOKEN}")
            self.assertEqual(received["headers"].get("authorization"), 'bearer abc"def')
            self.assertEqual(received["headers"].get("apns-topic"), "ELRD.App")
            self.assertEqual(received["body"], b'{"aps":{}}')
        finally:
            server.shutdown()
            server.server_close()

if __name__ == "__main__":
    unittest.main()
