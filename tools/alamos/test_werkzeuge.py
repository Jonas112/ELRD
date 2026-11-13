"""Tests für Testskript, FE2-Simulator und Hilfsmodule.

Ausführen:  python3 -m unittest -v test_werkzeuge   (im Ordner tools/alamos)
Mit Broker: ELRD_TEST_MQTT=localhost:1883:test-rd:entwicklung-fe2 …
Oberfläche: braucht eine Anzeige (macOS normal, Linux z. B. xvfb-run).
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import fe2_format as fe2  # noqa: E402
import mqtt_client  # noqa: E402
from elrd_backend import BackendError, app_alarms  # noqa: E402


class FormatTests(unittest.TestCase):
    def test_samples_are_valid_v2(self) -> None:
        self.assertEqual(fe2.sample_names(), ["bus", "intern", "pflegeheim", "vu"])
        for name in fe2.sample_names():
            envelope = fe2.load_sample(name, "4711")
            data = envelope["data"]
            self.assertEqual(envelope["type"], "ALARM")
            self.assertEqual(data["externalId"], "4711")
            self.assertNotIn("{{", json.dumps(envelope))
            longitude, latitude = data["location"]["coordinate"]
            self.assertTrue(5 < longitude < 16 and 47 < latitude < 56, "Reihenfolge [Länge, Breite]")
            self.assertEqual(data["custom"][fe2.TEST_MARKER], "true")
            self.assertTrue(all(v["alarmedTime"] > 0 for v in data["vehicles"]))

    def test_unknown_sample(self) -> None:
        with self.assertRaises(ValueError):
            fe2.load_sample("gibtsnicht")

    def test_changes(self) -> None:
        envelope = fe2.load_sample("vu", "1")
        for change in fe2.CHANGES:
            envelope = fe2.apply_change(envelope, change)
        data = envelope["data"]
        self.assertEqual(data["keyword"], "RD 3")
        self.assertEqual(len(data["vehicles"]), 3)
        self.assertEqual(len(data["patient"]), 2)
        self.assertEqual(data["location"]["additional"], "Zufahrt über Hinterhof")
        self.assertEqual(len(data["message"]), 2 + len(fe2.CHANGES))
        with self.assertRaises(ValueError):
            fe2.apply_change(envelope, "unsinn")

    def test_raise_keyword(self) -> None:
        self.assertEqual(fe2.raise_keyword("RD 2"), "RD 3")
        self.assertEqual(fe2.raise_keyword("B 3 Person"), "B 4 Person")
        self.assertEqual(fe2.raise_keyword("THL"), "THL +")

    def test_messages(self) -> None:
        self.assertEqual(fe2.close_message("9")["type"], "CLOSE")
        self.assertEqual(fe2.status_message("RK SWFT 71/1", "4")["data"]["status"], "4")
        self.assertEqual(fe2.topic(" elrd/ ", "test-rd"), "elrd/test-rd/alarm")
        self.assertEqual(fe2.vehicle("RK SWFT 76/1")["unitType"], "NEF")
        self.assertEqual(fe2.vehicle("BRK FW 11/1", "KdoW")["station"], "FW")
        self.assertEqual(fe2.patient("x", number=2), {"name": "", "remark": "x", "patientNumber": "2"})


class MqttTests(unittest.TestCase):
    def test_remaining_length(self) -> None:
        self.assertEqual(mqtt_client.encode_remaining_length(0), b"\x00")
        self.assertEqual(mqtt_client.encode_remaining_length(127), b"\x7f")
        self.assertEqual(mqtt_client.encode_remaining_length(128), b"\x80\x01")
        self.assertEqual(mqtt_client.encode_remaining_length(16_384), b"\x80\x80\x01")
        with self.assertRaises(mqtt_client.MqttError):
            mqtt_client.encode_remaining_length(268_435_456)

    def test_unreachable_broker_has_clear_message(self) -> None:
        with self.assertRaises(mqtt_client.MqttError) as context:
            mqtt_client.publish_once("t", "x", host="127.0.0.1", port=1, timeout=2)
        self.assertIn("nicht erreichbar", str(context.exception))

    @unittest.skipUnless(os.environ.get("ELRD_TEST_MQTT"), "ELRD_TEST_MQTT nicht gesetzt")
    def test_publish_to_real_broker(self) -> None:
        host, port, user, password = os.environ["ELRD_TEST_MQTT"].split(":")
        with mqtt_client.MqttConnection(host, int(port), user, password) as client:
            client.publish(f"elrd/{user}/alarm", fe2.to_json(fe2.load_sample("intern")), qos=1)
            client.publish(f"elrd/{user}/alarm", "qos0", qos=0)
        with self.assertRaises(mqtt_client.MqttError) as context:
            mqtt_client.publish_once("x", "y", host=host, port=int(port), username=user, password="falsch")
        self.assertIn("Passwort", str(context.exception))


class BackendTests(unittest.TestCase):
    def test_unreachable_backend(self) -> None:
        with self.assertRaises(BackendError):
            app_alarms("http://127.0.0.1:1", "schluessel")


class SimulatorTests(unittest.TestCase):
    """Oberfläche ohne Hauptschleife: Formular, Änderungen, Einstellungen."""

    @classmethod
    def setUpClass(cls) -> None:
        try:
            import tkinter
            cls.root = tkinter.Tk()
            cls.root.withdraw()
        except Exception as error:  # noqa: BLE001 – keine Anzeige/kein Tk
            raise unittest.SkipTest(f"Keine Oberfläche: {error}")
        import fe2_simulator
        cls.module = fe2_simulator

    @classmethod
    def tearDownClass(cls) -> None:
        cls.root.destroy()

    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.frame = self.module.tk.Toplevel(self.root)
        self.app = self.module.Simulator(self.frame, settings_path=Path(self.directory.name) / "einstellungen.json")

    def tearDown(self) -> None:
        self.frame.destroy()
        self.directory.cleanup()

    def test_form_round_trip(self) -> None:
        sample = fe2.load_sample("bus", "4711")
        sample["data"]["keyword_misc"] = "Zusatz"
        self.app.load_envelope(sample)
        envelope = self.app.form_envelope()
        data, original = envelope["data"], sample["data"]
        for key in ("externalId", "keyword", "keyword_description", "keyword_misc", "message", "location", "caller", "vehicles", "patient", "custom", "units"):
            self.assertEqual(data[key], original[key], key)

    def test_validation(self) -> None:
        self.app.v_number.set("")
        with self.assertRaises(ValueError):
            self.app.form_envelope()
        self.app.v_number.set("1")
        self.app.v_lat.set("abc")
        self.app.v_lng.set("10")
        with self.assertRaises(ValueError):
            self.app.form_envelope()
        self.app.v_lat.set("50,05")  # deutsches Komma
        self.assertEqual(self.app.form_envelope()["data"]["location"]["coordinate"], [10.0, 50.05])

    def test_vehicles_and_patients(self) -> None:
        self.app.load_envelope(fe2.empty_alarm("5"))
        self.app.v_vehicle.set("RK SWFT 76/2")
        self.app.add_vehicle()
        self.app.v_vehicle.set("rk swft 76/2")
        self.app.add_vehicle()  # doppelt → nicht hinzugefügt
        self.app.v_p_remark.set("Atemnot")
        self.app.add_patient()
        data = self.app.form_envelope()["data"]
        self.assertEqual([v["radioName"] for v in data["vehicles"]], ["RK SWFT 76/2"])
        self.assertEqual(data["vehicles"][0]["unitType"], "NEF")
        self.assertEqual(data["patient"], [{"name": "", "remark": "Atemnot", "patientNumber": "1"}])
        self.app.v_test.set(False)
        self.assertNotIn("custom", self.app.form_envelope()["data"])

    def test_json_tab(self) -> None:
        self.app.refresh_json()
        envelope = json.loads(self.app.json_text.get("1.0", "end"))
        envelope["data"]["keyword"] = "RD 5"
        self.app.json_text.delete("1.0", "end")
        self.app.json_text.insert("1.0", json.dumps(envelope))
        self.app.json_to_form()
        self.assertEqual(self.app.v_keyword.get(), "RD 5")

    def test_record_and_settings_without_secrets(self) -> None:
        envelope = self.app.form_envelope()
        self.app._record(envelope)
        self.app._record(fe2.close_message(envelope["data"]["externalId"]))
        entry = self.app.sent[envelope["data"]["externalId"]]
        self.assertEqual(entry["sends"], 2)
        self.assertTrue(entry["closed"])
        self.app.v_remember.set(False)
        self.app.v_password.set("geheim-123")
        self.app.save_settings()
        stored = self.app.settings_path.read_text(encoding="utf-8")
        self.assertNotIn("geheim-123", stored)
        self.assertNotIn("password", json.loads(stored))


if __name__ == "__main__":
    unittest.main()
