#!/usr/bin/env python3
"""FE2-Simulator – Alamos FE2 nachspielen, um die ELRD-App zu testen.

Sendet Einsätze im Datenformat V2 (wie das FE2-JSON-Plugin) über den MQTT-Broker
an das ELRD-Backend – genau wie FE2 mit dem MQTT-Plugin – oder direkt in die
Debug-Schnittstelle des Backends. Einsätze lassen sich frei bearbeiten, ändern
(Stichwort, Fahrzeuge, Patienten, Ort), schließen und als Ablauf abspielen. Die
„App-Sicht“ zeigt, was die App vom Backend bekommt.

Start: python3 fe2_simulator.py   (Anleitung: ANLEITUNG-macOS.md)
Nur Python-Standardbibliothek (tkinter).
"""

from __future__ import annotations

import copy
import json
import os
import queue
import subprocess
import sys
import threading
from datetime import datetime
from pathlib import Path
from typing import Any, Callable

sys.path.insert(0, str(Path(__file__).resolve().parent))

try:
    import tkinter as tk
    from tkinter import filedialog, messagebox, ttk
except ImportError:  # pragma: no cover - Hinweis für macOS ohne Tk
    sys.exit(
        "tkinter fehlt. macOS mit Homebrew: brew install python-tk\n"
        "Oder Python von python.org installieren (enthält Tk). Siehe ANLEITUNG-macOS.md."
    )

import fe2_format as fe2  # noqa: E402
from elrd_backend import BackendError, admin_status, app_alarms, app_ping, send_raw  # noqa: E402
from mqtt_client import MqttConnection, MqttError, publish_once  # noqa: E402

APP_NAME = "ELRD FE2-Simulator"
KEYCHAIN_SERVICE = "ELRD FE2-Simulator"
IS_MAC = sys.platform == "darwin"

# Felder von data, die das Formular selbst pflegt (alles andere bleibt beim Bearbeiten erhalten).
FORM_FIELDS = {
    "externalId", "keyword", "keyword_description", "keyword_misc", "message",
    "location", "caller", "vehicles", "patient", "custom",
}


# MARK: Einstellungen und Schlüsselbund

def config_dir() -> Path:
    if IS_MAC:
        base = Path.home() / "Library" / "Application Support" / APP_NAME
    else:
        base = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "elrd-fe2-simulator"
    base.mkdir(parents=True, exist_ok=True)
    return base


def keychain_get(account: str) -> str | None:
    """Geheimnis aus dem macOS-Schlüsselbund (sonst nicht gespeichert)."""
    if not IS_MAC:
        return None
    result = subprocess.run(
        ["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-a", account, "-w"],
        capture_output=True, text=True,
    )
    return result.stdout.rstrip("\n") if result.returncode == 0 else None


def keychain_set(account: str, value: str) -> None:
    if not IS_MAC:
        return
    if value:
        subprocess.run(
            ["security", "add-generic-password", "-U", "-s", KEYCHAIN_SERVICE, "-a", account, "-w", value],
            capture_output=True,
        )
    else:
        subprocess.run(["security", "delete-generic-password", "-s", KEYCHAIN_SERVICE, "-a", account], capture_output=True)


SECRET_FIELDS = {"password": "mqtt-passwort", "admin_key": "admin-schluessel", "app_key": "app-schluessel"}

DEFAULTS: dict[str, Any] = {
    "way": "mqtt",
    "host": os.environ.get("ELRD_MQTT_HOST", "localhost"),
    "port": int(os.environ.get("ELRD_MQTT_PORT", "1883")),
    "tls": False,
    "cafile": "",
    "user": os.environ.get("ELRD_MQTT_USER", "test-rd"),
    "password": os.environ.get("ELRD_MQTT_PASS", "entwicklung-fe2"),
    "org": os.environ.get("ELRD_ORG", "test-rd"),
    "prefix": "elrd",
    "backend": os.environ.get("ELRD_BACKEND", "http://localhost:8080"),
    "admin_key": os.environ.get("ELRD_ADMIN_KEY", "entwicklung-admin-schluessel"),
    "app_key": os.environ.get("ELRD_APP_KEY", ""),
    "sender": "ILS Simulator",
    "remember_secrets": IS_MAC,
    "pause": 15,
}


# MARK: Oberfläche

class Simulator:
    def __init__(self, root: tk.Tk, settings_path: Path | None = None) -> None:
        self.root = root
        self.settings_path = settings_path or config_dir() / "einstellungen.json"
        self.alarms_path = self.settings_path.with_name("einsaetze.json")
        self.events: queue.Queue[tuple[str, Any]] = queue.Queue()
        # Nummer → {"envelope": letzte ALARM-Nachricht, "sends": Anzahl, "closed": bool, "time": str}
        self.sent: dict[str, dict[str, Any]] = {}
        self.vehicles: list[dict] = []
        self.patients: list[dict] = []
        self.extra_data: dict = {"units": [{"address": "ELRD"}]}
        self.extra_custom: dict = {}
        self.busy = False
        self.scenario_stop: threading.Event | None = None

        root.title(APP_NAME)
        root.geometry("1400x940")
        root.minsize(1080, 720)
        self._make_vars()
        self._build()
        self._load_settings()
        self._load_alarms()
        self.load_sample()
        root.protocol("WM_DELETE_WINDOW", self.quit)
        root.after(100, self._drain_events)
        root.after(5000, self._auto_refresh)
        if float(tk.TkVersion) < 8.6:
            self.log("Hinweis: Tk 8.5 (System-Python von macOS) zeichnet unsauber – besser Homebrew-Python mit python-tk.", "warn")

    # MARK: Variablen

    def _make_vars(self) -> None:
        S, B, I = tk.StringVar, tk.BooleanVar, tk.IntVar
        self.v_way, self.v_host, self.v_port = S(), S(), I()
        self.v_tls, self.v_cafile = B(), S()
        self.v_user, self.v_password, self.v_org, self.v_prefix = S(), S(), S(), S()
        self.v_backend, self.v_admin_key, self.v_app_key = S(), S(), S()
        self.v_remember, self.v_pause, self.v_auto_app = B(), I(), B(value=True)
        self.v_topic, self.v_status = S(), S(value="Bereit.")
        # Formular
        self.v_number, self.v_sender, self.v_keyword = S(), S(), S()
        self.v_description, self.v_misc, self.v_test = S(), S(), B(value=True)
        self.v_building, self.v_street, self.v_house = S(), S(), S()
        self.v_postal, self.v_city, self.v_additional = S(), S(), S()
        self.v_lat, self.v_lng = S(), S()
        self.v_caller, self.v_contact = S(), S()
        self.v_sample = S()
        # Fahrzeug- und Patienteneingabe
        self.v_vehicle, self.v_vehicle_type, self.v_station = S(), S(), S()
        self.v_p_name, self.v_p_remark, self.v_p_dest, self.v_p_number = S(), S(), S(), S()
        self.v_status_code = S(value="3")
        for var in (self.v_prefix, self.v_org):
            var.trace_add("write", lambda *_: self.v_topic.set(fe2.topic(self.v_prefix.get(), self.v_org.get())))
        self.v_way.trace_add("write", lambda *_: self._update_way())
        self.v_tls.trace_add("write", lambda *_: self._tls_changed())

    # MARK: Aufbau

    def _build(self) -> None:
        outer = ttk.Frame(self.root, padding=10)
        outer.pack(fill="both", expand=True)
        self._build_connection(outer)
        # Aktionen und Protokoll fest unten; die Mitte bekommt den restlichen Platz.
        bottom = ttk.Frame(outer)
        bottom.pack(side="bottom", fill="x")
        self._build_actions(bottom)
        self._build_log(bottom)

        panes = ttk.PanedWindow(outer, orient="horizontal")
        panes.pack(fill="both", expand=True, pady=(8, 0))
        panes.add(self._build_sent_list(panes), weight=2)
        panes.add(self._build_editor(panes), weight=5)
        self.root.after(200, lambda: panes.sashpos(0, 470))

    def _build_connection(self, parent: ttk.Frame) -> None:
        box = ttk.LabelFrame(parent, text="Verbindung", padding=8)
        box.pack(fill="x")
        row0 = ttk.Frame(box)
        row0.pack(fill="x")
        ttk.Label(row0, text="Weg:").pack(side="left")
        ttk.Radiobutton(row0, text="MQTT wie FE2", variable=self.v_way, value="mqtt").pack(side="left", padx=(6, 0))
        ttk.Radiobutton(row0, text="HTTP direkt ins Backend (Debug)", variable=self.v_way, value="http").pack(side="left", padx=6)
        ttk.Separator(row0, orient="vertical").pack(side="left", fill="y", padx=10)
        ttk.Label(row0, text="Organisation").pack(side="left")
        ttk.Entry(row0, textvariable=self.v_org, width=16).pack(side="left", padx=4)
        ttk.Label(row0, text="Topic-Präfix").pack(side="left", padx=(8, 0))
        ttk.Entry(row0, textvariable=self.v_prefix, width=8).pack(side="left", padx=4)
        ttk.Label(row0, text="→").pack(side="left")
        ttk.Label(row0, textvariable=self.v_topic, font=("Menlo", 12) if IS_MAC else "TkFixedFont").pack(side="left", padx=4)
        ttk.Button(row0, text="Verbindung testen", command=self.test_connection).pack(side="right")
        if IS_MAC:
            ttk.Checkbutton(row0, text="Zugangsdaten im Schlüsselbund merken", variable=self.v_remember).pack(side="right", padx=10)

        self.mqtt_row = ttk.Frame(box)
        self.mqtt_row.pack(fill="x", pady=(6, 0))
        r = self.mqtt_row
        ttk.Label(r, text="Broker").pack(side="left")
        ttk.Entry(r, textvariable=self.v_host, width=24).pack(side="left", padx=4)
        ttk.Label(r, text="Port").pack(side="left")
        ttk.Spinbox(r, textvariable=self.v_port, from_=1, to=65535, width=6).pack(side="left", padx=4)
        ttk.Checkbutton(r, text="TLS", variable=self.v_tls).pack(side="left", padx=4)
        ttk.Label(r, text="Benutzer").pack(side="left", padx=(10, 0))
        ttk.Entry(r, textvariable=self.v_user, width=16).pack(side="left", padx=4)
        ttk.Label(r, text="Passwort").pack(side="left")
        ttk.Entry(r, textvariable=self.v_password, width=18, show="•").pack(side="left", padx=4)
        ttk.Label(r, text="CA-Datei").pack(side="left", padx=(10, 0))
        ttk.Entry(r, textvariable=self.v_cafile, width=14).pack(side="left", padx=4)
        ttk.Button(r, text="…", width=2, command=self._choose_cafile).pack(side="left")

        row2 = ttk.Frame(box)
        row2.pack(fill="x", pady=(6, 0))
        ttk.Label(row2, text="Backend").pack(side="left")
        ttk.Entry(row2, textvariable=self.v_backend, width=30).pack(side="left", padx=4)
        ttk.Label(row2, text="Admin-Schlüssel").pack(side="left", padx=(10, 0))
        ttk.Entry(row2, textvariable=self.v_admin_key, width=24, show="•").pack(side="left", padx=4)
        ttk.Label(row2, text="App-Schlüssel (für die App-Sicht)").pack(side="left", padx=(10, 0))
        ttk.Entry(row2, textvariable=self.v_app_key, width=28, show="•").pack(side="left", padx=4)

    def _build_sent_list(self, parent: ttk.PanedWindow) -> ttk.Frame:
        frame = ttk.LabelFrame(parent, text="Gesendete Einsätze", padding=6)
        columns = ("keyword", "title", "state")
        tree = ttk.Treeview(frame, columns=columns, show="tree headings", selectmode="browse", height=6)
        tree.heading("#0", text="Nummer")
        tree.column("#0", width=165, stretch=False)
        for column, title, width in (("keyword", "Stw.", 50), ("title", "Meldebild", 110), ("state", "Status", 95)):
            tree.heading(column, text=title)
            tree.column(column, width=width, stretch=column == "title")
        tree.pack(fill="both", expand=True)
        tree.bind("<<TreeviewSelect>>", lambda _: self._select_sent())
        self.sent_tree = tree

        ttk.Label(frame, text="Neuer Einsatz aus Vorlage:").pack(anchor="w", pady=(8, 2))
        row = ttk.Frame(frame)
        row.pack(fill="x")
        names = ["leer"] + fe2.sample_names()
        self.sample_titles = {"leer": "leeres Formular"} | {name: fe2.sample_title(name) for name in fe2.sample_names()}
        combo = ttk.Combobox(row, textvariable=self.v_sample, state="readonly",
                             values=[f"{n}: {self.sample_titles[n]}" for n in names])
        combo.current(1 if len(names) > 1 else 0)
        combo.pack(side="left", fill="x", expand=True)
        ttk.Button(row, text="Laden", command=self.load_sample).pack(side="left", padx=(4, 0))
        row2 = ttk.Frame(frame)
        row2.pack(fill="x", pady=(6, 0))
        ttk.Button(row2, text="Auswahl entfernen", command=self._forget_selected).pack(side="left")
        ttk.Button(row2, text="Liste leeren", command=self._forget_all).pack(side="right")
        return frame

    def _build_editor(self, parent: ttk.PanedWindow) -> ttk.Notebook:
        notebook = ttk.Notebook(parent)
        self.notebook = notebook
        notebook.add(self._build_alarm_tab(notebook), text="Einsatz")
        self.vehicle_tab = self._build_vehicle_tab(notebook)
        notebook.add(self.vehicle_tab, text="Fahrzeuge")
        self.patient_tab = self._build_patient_tab(notebook)
        notebook.add(self.patient_tab, text="Patienten")
        self.json_tab = self._build_json_tab(notebook)
        notebook.add(self.json_tab, text="JSON")
        self.app_tab = self._build_app_tab(notebook)
        notebook.add(self.app_tab, text="App-Sicht")
        notebook.bind("<<NotebookTabChanged>>", lambda _: self._tab_changed())
        return notebook

    def _field(self, parent: ttk.Frame, row: int, column: int, label: str, var: tk.Variable, width: int = 22, span: int = 1, widget: str = "entry", values: list[str] | None = None) -> ttk.Widget:
        ttk.Label(parent, text=label).grid(row=row, column=column, sticky="w", padx=(0, 6), pady=3)
        if widget == "combo":
            entry: ttk.Widget = ttk.Combobox(parent, textvariable=var, width=width, values=values or [])
        else:
            entry = ttk.Entry(parent, textvariable=var, width=width)
        entry.grid(row=row, column=column + 1, columnspan=span, sticky="we", padx=(0, 14), pady=3)
        return entry

    def _build_alarm_tab(self, notebook: ttk.Notebook) -> ttk.Frame:
        tab = ttk.Frame(notebook, padding=12)
        for column in (1, 3, 5):
            tab.columnconfigure(column, weight=1)
        f = self._field
        f(tab, 0, 0, "Einsatznummer", self.v_number, width=24)
        ttk.Button(tab, text="Neue Nummer", command=lambda: self.v_number.set(fe2.new_number())).grid(row=0, column=2, sticky="w")
        f(tab, 0, 3, "Absender", self.v_sender)
        ttk.Checkbutton(tab, text="Testeinsatz", variable=self.v_test).grid(row=0, column=5, sticky="w")

        ttk.Separator(tab).grid(row=1, column=0, columnspan=6, sticky="we", pady=8)
        f(tab, 2, 0, "Stichwort", self.v_keyword, widget="combo", values=fe2.KEYWORDS)
        f(tab, 2, 2, "Meldebild", self.v_description, width=34, span=3)
        f(tab, 3, 0, "Zusatz (keyword_misc)", self.v_misc, width=34, span=5)

        ttk.Label(tab, text="Alarmtext (je Zeile ein Eintrag)").grid(row=4, column=0, sticky="nw", pady=3)
        self.message_text = tk.Text(tab, height=5, wrap="word", undo=True)
        self.message_text.grid(row=4, column=1, columnspan=5, sticky="nsew", pady=3, padx=(0, 14))
        tab.rowconfigure(4, weight=1)

        ttk.Separator(tab).grid(row=5, column=0, columnspan=6, sticky="we", pady=8)
        ttk.Label(tab, text="Einsatzort", font="TkHeadingFont").grid(row=6, column=0, sticky="w")
        f(tab, 7, 0, "Objekt", self.v_building)
        f(tab, 7, 2, "Straße", self.v_street)
        f(tab, 7, 4, "Hausnummer", self.v_house, width=8)
        f(tab, 8, 0, "PLZ", self.v_postal, width=8)
        f(tab, 8, 2, "Ort", self.v_city)
        f(tab, 8, 4, "Zusatz", self.v_additional)
        f(tab, 9, 0, "Breite (lat)", self.v_lat, width=12)
        f(tab, 9, 2, "Länge (lng)", self.v_lng, width=12)
        ttk.Label(tab, text="(FE2-Reihenfolge [Länge, Breite] stellt der Simulator her)", foreground="gray").grid(row=9, column=4, columnspan=2, sticky="w")

        ttk.Separator(tab).grid(row=10, column=0, columnspan=6, sticky="we", pady=8)
        f(tab, 11, 0, "Anrufer", self.v_caller)
        f(tab, 11, 2, "Rückruf", self.v_contact)
        return tab

    def _build_vehicle_tab(self, notebook: ttk.Notebook) -> ttk.Frame:
        tab = ttk.Frame(notebook, padding=12)
        tree = ttk.Treeview(tab, columns=("type", "station", "time"), show="tree headings", selectmode="browse")
        tree.heading("#0", text="Funkrufname")
        tree.column("#0", width=200)
        for column, title in (("type", "Typ"), ("station", "Wache"), ("time", "alarmiert")):
            tree.heading(column, text=title)
            tree.column(column, width=110)
        tree.pack(fill="both", expand=True)
        self.vehicle_tree = tree
        row = ttk.Frame(tab)
        row.pack(fill="x", pady=(8, 0))
        ttk.Label(row, text="Funkrufname").pack(side="left")
        ttk.Combobox(row, textvariable=self.v_vehicle, values=fe2.VEHICLE_POOL, width=20).pack(side="left", padx=4)
        ttk.Label(row, text="Typ").pack(side="left")
        ttk.Combobox(row, textvariable=self.v_vehicle_type, values=[""] + fe2.UNIT_TYPES, width=10).pack(side="left", padx=4)
        ttk.Label(row, text="Wache").pack(side="left")
        ttk.Entry(row, textvariable=self.v_station, width=10).pack(side="left", padx=4)
        ttk.Button(row, text="Hinzufügen", command=self.add_vehicle).pack(side="left", padx=4)
        ttk.Button(row, text="Entfernen", command=self.remove_vehicle).pack(side="left")
        ttk.Label(tab, text="Typ leer = aus dem Funkrufnamen geschätzt (71 RTW, 72 KTW, 76 NEF). Funkrufnamen aus den Stammdaten ordnet die App automatisch zu.",
                  foreground="gray").pack(anchor="w", pady=(6, 0))
        return tab

    def _build_patient_tab(self, notebook: ttk.Notebook) -> ttk.Frame:
        tab = ttk.Frame(notebook, padding=12)
        tree = ttk.Treeview(tab, columns=("name", "remark", "dest"), show="tree headings", selectmode="browse")
        tree.heading("#0", text="Nr.")
        tree.column("#0", width=60, stretch=False)
        for column, title, width in (("name", "Name", 160), ("remark", "Bemerkung", 320), ("dest", "Ziel", 160)):
            tree.heading(column, text=title)
            tree.column(column, width=width)
        tree.pack(fill="both", expand=True)
        tree.bind("<<TreeviewSelect>>", lambda _: self._select_patient())
        self.patient_tree = tree
        row = ttk.Frame(tab)
        row.pack(fill="x", pady=(8, 0))
        for label, var, width in (("Nr.", self.v_p_number, 4), ("Name", self.v_p_name, 16), ("Bemerkung", self.v_p_remark, 30), ("Ziel", self.v_p_dest, 16)):
            ttk.Label(row, text=label).pack(side="left")
            ttk.Entry(row, textvariable=var, width=width).pack(side="left", padx=4)
        row2 = ttk.Frame(tab)
        row2.pack(fill="x", pady=(6, 0))
        ttk.Button(row2, text="Hinzufügen", command=self.add_patient).pack(side="left")
        ttk.Button(row2, text="Auswahl ändern", command=self.update_patient).pack(side="left", padx=4)
        ttk.Button(row2, text="Entfernen", command=self.remove_patient).pack(side="left")
        ttk.Label(tab, text="Die App legt gemeldete Patienten ungesichtet an; Bemerkung und Ziel landen in der Notiz.",
                  foreground="gray").pack(anchor="w", pady=(6, 0))
        return tab

    def _build_json_tab(self, notebook: ttk.Notebook) -> ttk.Frame:
        tab = ttk.Frame(notebook, padding=12)
        self.json_text = tk.Text(tab, wrap="none", undo=True, font=("Menlo", 12) if IS_MAC else "TkFixedFont")
        scroll = ttk.Scrollbar(tab, orient="vertical", command=self.json_text.yview)
        self.json_text.configure(yscrollcommand=scroll.set)
        row = ttk.Frame(tab)
        row.pack(side="bottom", fill="x", pady=(8, 0))
        ttk.Button(row, text="Aus Formular erzeugen", command=self.refresh_json).pack(side="left")
        ttk.Button(row, text="Ins Formular übernehmen", command=self.json_to_form).pack(side="left", padx=4)
        ttk.Button(row, text="Genau dieses JSON senden", command=self.send_json).pack(side="left")
        ttk.Label(row, text="= Ausgabe des FE2-JSON-Plugins (V2)", foreground="gray").pack(side="right")
        scroll.pack(side="right", fill="y")
        self.json_text.pack(fill="both", expand=True)
        return tab

    def _build_app_tab(self, notebook: ttk.Notebook) -> ttk.Frame:
        tab = ttk.Frame(notebook, padding=12)
        row = ttk.Frame(tab)
        row.pack(fill="x")
        ttk.Button(row, text="Jetzt abrufen", command=self.fetch_app_view).pack(side="left")
        ttk.Checkbutton(row, text="alle 5 s aktualisieren", variable=self.v_auto_app).pack(side="left", padx=8)
        self.app_info = ttk.Label(row, text="Zeigt die Einsätze, die die App mit dem App-Schlüssel vom Backend bekommt.", foreground="gray")
        self.app_info.pack(side="left", padx=8)
        columns = ("keyword", "title", "revision", "source", "test", "closed", "updated")
        tree = ttk.Treeview(tab, columns=columns, show="tree headings")
        tree.heading("#0", text="Nummer")
        tree.column("#0", width=170)
        for column, title, width in (("keyword", "Stw.", 55), ("title", "Meldebild", 240), ("revision", "Stand", 50),
                                     ("source", "Quelle", 60), ("test", "Test", 45), ("closed", "geschlossen", 95), ("updated", "geändert", 80)):
            tree.heading(column, text=title)
            tree.column(column, width=width, stretch=column == "title")
        tree.pack(fill="both", expand=True, pady=(8, 0))
        self.app_tree = tree
        return tab

    def _build_actions(self, parent: ttk.Frame) -> None:
        self.action_buttons: list[ttk.Button] = []

        def button(container: ttk.Frame, text: str, command: Callable[[], None], **pack: Any) -> None:
            item = ttk.Button(container, text=text, command=command)
            item.pack(side="left", **pack)
            self.action_buttons.append(item)

        top = ttk.Frame(parent)
        top.pack(fill="x", pady=(8, 0))
        main = ttk.LabelFrame(top, text="Senden", padding=6)
        main.pack(side="left")
        button(main, "▶ Als neuen Einsatz senden", self.send_new)
        button(main, "⟳ Änderung senden", self.send_update, padx=(4, 0))
        quick = ttk.LabelFrame(top, text="Leitstelle ändert (und sendet sofort)", padding=6)
        quick.pack(side="left", padx=(8, 0), fill="x", expand=True)
        for key, title in fe2.CHANGES.items():
            button(quick, title, lambda key=key: self.quick_change(key), padx=(0, 4))

        bottom = ttk.Frame(parent)
        bottom.pack(fill="x", pady=(6, 0))
        close = ttk.LabelFrame(bottom, text="Einsatz beenden", padding=6)
        close.pack(side="left")
        button(close, "Schließen (CLOSE)", self.send_close)
        status = ttk.LabelFrame(bottom, text="Fahrzeugstatus (wird vom Backend ignoriert)", padding=6)
        status.pack(side="left", padx=8)
        ttk.Combobox(status, textvariable=self.v_status_code, values=[str(n) for n in range(1, 10)], width=3).pack(side="left")
        button(status, "Status senden", self.send_status, padx=(4, 0))
        scenario = ttk.LabelFrame(bottom, text="Ablauf: neu → Stichwort → Fahrzeug → Patient → Nachmeldung → Ort → CLOSE", padding=6)
        scenario.pack(side="left", fill="x", expand=True)
        ttk.Label(scenario, text="Pause").pack(side="left")
        ttk.Spinbox(scenario, textvariable=self.v_pause, from_=1, to=600, width=4).pack(side="left", padx=4)
        ttk.Label(scenario, text="s").pack(side="left")
        self.scenario_button = ttk.Button(scenario, text="Abspielen", command=self.toggle_scenario)
        self.scenario_button.pack(side="left", padx=(8, 0))

    def _build_log(self, parent: ttk.Frame) -> None:
        box = ttk.LabelFrame(parent, text="Protokoll", padding=6)
        box.pack(fill="x", pady=(8, 0))
        self.log_text = tk.Text(box, height=6, state="disabled", wrap="word", font=("Menlo", 11) if IS_MAC else "TkFixedFont")
        self.log_text.tag_configure("ok", foreground="#1f8a3b")
        self.log_text.tag_configure("error", foreground="#d0021b")
        self.log_text.tag_configure("warn", foreground="#c76a00")
        self.log_text.tag_configure("time", foreground="gray")
        self.log_text.pack(fill="x")
        ttk.Label(parent, textvariable=self.v_status, foreground="gray").pack(anchor="w", pady=(4, 0))

    # MARK: Einstellungen

    def _load_settings(self) -> None:
        stored: dict = {}
        if self.settings_path.exists():
            try:
                stored = json.loads(self.settings_path.read_text(encoding="utf-8"))
            except json.JSONDecodeError:
                stored = {}
        values = DEFAULTS | {k: v for k, v in stored.items() if k not in SECRET_FIELDS}
        if values.get("remember_secrets"):
            for field, account in SECRET_FIELDS.items():
                secret = keychain_get(account)
                if secret is not None:
                    values[field] = secret
        mapping = self._settings_vars()
        for key, var in mapping.items():
            var.set(values[key])
        self._update_way()

    def _settings_vars(self) -> dict[str, tk.Variable]:
        return {
            "way": self.v_way, "host": self.v_host, "port": self.v_port, "tls": self.v_tls, "cafile": self.v_cafile,
            "user": self.v_user, "password": self.v_password, "org": self.v_org, "prefix": self.v_prefix,
            "backend": self.v_backend, "admin_key": self.v_admin_key, "app_key": self.v_app_key,
            "sender": self.v_sender, "remember_secrets": self.v_remember, "pause": self.v_pause,
        }

    def save_settings(self) -> None:
        values = {}
        for key, var in self._settings_vars().items():
            try:
                values[key] = var.get()
            except tk.TclError:
                values[key] = DEFAULTS[key]
        secrets = {field: values.pop(field) for field in SECRET_FIELDS}
        if values.get("remember_secrets"):
            for field, account in SECRET_FIELDS.items():
                keychain_set(account, secrets[field])
        # Geheimnisse nie in die Datei.
        self.settings_path.write_text(json.dumps(values, ensure_ascii=False, indent=2), encoding="utf-8")

    def _load_alarms(self) -> None:
        if self.alarms_path.exists():
            try:
                self.sent = json.loads(self.alarms_path.read_text(encoding="utf-8"))
            except json.JSONDecodeError:
                self.sent = {}
        self._render_sent()

    def _save_alarms(self) -> None:
        self.alarms_path.write_text(json.dumps(self.sent, ensure_ascii=False, indent=2), encoding="utf-8")

    def quit(self) -> None:
        if self.scenario_stop:
            self.scenario_stop.set()
        try:
            self.save_settings()
            self._save_alarms()
        finally:
            self.root.destroy()

    # MARK: Formular ↔ Nachricht

    def load_envelope(self, envelope: dict) -> None:
        data = envelope.get("data", {})
        location = data.get("location") or {}
        caller = data.get("caller") or {}
        custom = dict(data.get("custom") or {})
        self.v_number.set(str(data.get("externalId", "")))
        if envelope.get("sender"):
            self.v_sender.set(envelope["sender"])
        self.v_keyword.set(data.get("keyword", ""))
        self.v_description.set(data.get("keyword_description", ""))
        self.v_misc.set(data.get("keyword_misc", ""))
        self.message_text.delete("1.0", "end")
        message = data.get("message") or []
        self.message_text.insert("1.0", "\n".join(message) if isinstance(message, list) else str(message))
        for var, key in ((self.v_building, "building"), (self.v_street, "street"), (self.v_house, "house"),
                         (self.v_postal, "postalCode"), (self.v_city, "city"), (self.v_additional, "additional")):
            var.set(str(location.get(key, "")))
        coordinate = location.get("coordinate")
        if isinstance(coordinate, list) and len(coordinate) == 2:
            self.v_lng.set(str(coordinate[0]))
            self.v_lat.set(str(coordinate[1]))
        else:
            self.v_lng.set("")
            self.v_lat.set("")
        self.v_caller.set(caller.get("name", ""))
        self.v_contact.set(caller.get("contact", ""))
        self.v_test.set(custom.pop(fe2.TEST_MARKER, None) == "true")
        self.extra_custom = custom
        self.vehicles = copy.deepcopy(data.get("vehicles") or [])
        self.patients = copy.deepcopy(data.get("patient") or [])
        self.extra_data = {k: copy.deepcopy(v) for k, v in data.items() if k not in FORM_FIELDS}
        self._render_vehicles()
        self._render_patients()

    def form_envelope(self) -> dict:
        """Nachricht aus dem Formular; ValueError bei ungültigen Angaben."""
        number = self.v_number.get().strip()
        if not number:
            raise ValueError("Bitte eine Einsatznummer angeben (oder „Neue Nummer“).")
        data: dict = {"externalId": number}
        data["keyword"] = self.v_keyword.get().strip()
        data["keyword_description"] = self.v_description.get().strip()
        if self.v_misc.get().strip():
            data["keyword_misc"] = self.v_misc.get().strip()
        data["message"] = [line for line in self.message_text.get("1.0", "end").splitlines() if line.strip()]
        location: dict = {}
        lat, lng = self.v_lat.get().strip().replace(",", "."), self.v_lng.get().strip().replace(",", ".")
        if lat or lng:
            try:
                latitude, longitude = float(lat), float(lng)
            except ValueError:
                raise ValueError("Breite und Länge als Zahl angeben, z. B. 50.0494 und 10.2341.") from None
            if not (-90 <= latitude <= 90 and -180 <= longitude <= 180):
                raise ValueError("Koordinate außerhalb des gültigen Bereichs.")
            location["coordinate"] = [longitude, latitude]
        for key, var in (("building", self.v_building), ("street", self.v_street), ("house", self.v_house),
                         ("postalCode", self.v_postal), ("city", self.v_city), ("additional", self.v_additional)):
            if var.get().strip():
                location[key] = var.get().strip()
        data["location"] = location
        if self.v_caller.get().strip() or self.v_contact.get().strip():
            data["caller"] = {"name": self.v_caller.get().strip(), "contact": self.v_contact.get().strip()}
        data["vehicles"] = copy.deepcopy(self.vehicles)
        if self.patients:
            data["patient"] = copy.deepcopy(self.patients)
        custom = dict(self.extra_custom)
        if self.v_test.get():
            custom[fe2.TEST_MARKER] = "true"
        if custom:
            data["custom"] = custom
        # Felder, die das Formular nicht kennt (z. B. units), unverändert mitschicken.
        for key, value in self.extra_data.items():
            data.setdefault(key, copy.deepcopy(value))
        return {"type": "ALARM", "timestamp": fe2.now_iso(), "sender": self.v_sender.get().strip() or "FE2-Simulator", "data": data}

    # MARK: Fahrzeuge und Patienten

    def _render_vehicles(self) -> None:
        self.vehicle_tree.delete(*self.vehicle_tree.get_children())
        for index, vehicle in enumerate(self.vehicles):
            alarmed = vehicle.get("alarmedTime")
            when = datetime.fromtimestamp(alarmed / 1000).strftime("%H:%M:%S") if isinstance(alarmed, (int, float)) and alarmed > 0 else ""
            self.vehicle_tree.insert("", "end", iid=str(index), text=vehicle.get("radioName") or vehicle.get("name", ""),
                                     values=(vehicle.get("unitType", ""), vehicle.get("station", ""), when))
        self.notebook.tab(self.vehicle_tab, text=f"Fahrzeuge ({len(self.vehicles)})")

    def add_vehicle(self) -> None:
        name = self.v_vehicle.get().strip()
        if not name:
            return
        if any((v.get("radioName") or "").lower() == name.lower() for v in self.vehicles):
            self.log(f"{name} ist schon alarmiert.", "warn")
            return
        self.vehicles.append(fe2.vehicle(name, self.v_vehicle_type.get().strip() or None, self.v_station.get().strip() or None))
        self.v_vehicle.set("")
        self._render_vehicles()

    def remove_vehicle(self) -> None:
        selection = self.vehicle_tree.selection()
        if selection:
            del self.vehicles[int(selection[0])]
            self._render_vehicles()

    def _render_patients(self) -> None:
        self.patient_tree.delete(*self.patient_tree.get_children())
        for index, entry in enumerate(self.patients):
            self.patient_tree.insert("", "end", iid=str(index), text=entry.get("patientNumber", ""),
                                     values=(entry.get("name", ""), entry.get("remark", ""), entry.get("destination", "")))
        self.notebook.tab(self.patient_tab, text=f"Patienten ({len(self.patients)})")
        self.v_p_number.set(str(len(self.patients) + 1))

    def _patient_from_inputs(self) -> dict:
        return fe2.patient(self.v_p_remark.get().strip(), self.v_p_name.get().strip(), self.v_p_dest.get().strip(), self.v_p_number.get().strip())

    def add_patient(self) -> None:
        self.patients.append(self._patient_from_inputs())
        for var in (self.v_p_name, self.v_p_remark, self.v_p_dest):
            var.set("")
        self._render_patients()

    def _select_patient(self) -> None:
        selection = self.patient_tree.selection()
        if not selection:
            return
        entry = self.patients[int(selection[0])]
        self.v_p_number.set(entry.get("patientNumber", ""))
        self.v_p_name.set(entry.get("name", ""))
        self.v_p_remark.set(entry.get("remark", ""))
        self.v_p_dest.set(entry.get("destination", ""))

    def update_patient(self) -> None:
        selection = self.patient_tree.selection()
        if selection:
            self.patients[int(selection[0])] = self._patient_from_inputs()
            self._render_patients()

    def remove_patient(self) -> None:
        selection = self.patient_tree.selection()
        if selection:
            del self.patients[int(selection[0])]
            self._render_patients()

    # MARK: Liste der gesendeten Einsätze

    def _render_sent(self) -> None:
        selected = self.sent_tree.selection()
        self.sent_tree.delete(*self.sent_tree.get_children())
        for number, entry in sorted(self.sent.items(), key=lambda item: item[1].get("time", ""), reverse=True):
            data = entry["envelope"].get("data", {})
            state = "geschlossen" if entry.get("closed") else f"offen · {entry.get('sends', 1)}×"
            self.sent_tree.insert("", "end", iid=number, text=number, values=(
                data.get("keyword", ""), data.get("keyword_description", ""), state,
            ))
        if selected and self.sent_tree.exists(selected[0]):
            self.sent_tree.selection_set(selected[0])

    def _select_sent(self) -> None:
        selection = self.sent_tree.selection()
        if selection and selection[0] in self.sent and selection[0] != self.v_number.get():
            self.load_envelope(self.sent[selection[0]]["envelope"])
            self._tab_changed()

    def _record(self, envelope: dict) -> None:
        data = envelope.get("data", {})
        number = str(data.get("externalId", ""))
        if not number:
            return
        entry = self.sent.setdefault(number, {"envelope": envelope, "sends": 0, "closed": False})
        entry["sends"] = entry.get("sends", 0) + 1
        entry["time"] = datetime.now().isoformat(timespec="seconds")
        if envelope.get("type") == "CLOSE":
            entry["closed"] = True
        elif envelope.get("type") == "ALARM":
            entry["envelope"] = envelope
            entry["closed"] = False
        self._save_alarms()
        self._render_sent()
        if self.sent_tree.exists(number):
            self.sent_tree.selection_set(number)

    def _forget_selected(self) -> None:
        for number in self.sent_tree.selection():
            self.sent.pop(number, None)
        self._save_alarms()
        self._render_sent()

    def _forget_all(self) -> None:
        if self.sent and messagebox.askyesno(APP_NAME, "Liste der gesendeten Einsätze leeren?\n(Im Backend bleiben sie bis zum Ablauf der Aufbewahrung.)"):
            self.sent.clear()
            self._save_alarms()
            self._render_sent()

    def load_sample(self) -> None:
        name = self.v_sample.get().split(":")[0]
        envelope = fe2.empty_alarm(sender=self.v_sender.get() or "FE2-Simulator") if name == "leer" else fe2.load_sample(name)
        envelope["sender"] = self.v_sender.get() or envelope.get("sender")
        self.load_envelope(envelope)
        self.sent_tree.selection_remove(*self.sent_tree.selection())
        self.notebook.select(0)
        self.log(f"Vorlage „{self.sample_titles.get(name, name)}“ geladen – noch nicht gesendet.")

    # MARK: Senden

    def _connection(self) -> dict[str, Any]:
        """Momentaufnahme der Verbindung (Tk-Variablen nur im Hauptthread lesen)."""
        try:
            port = int(self.v_port.get())
        except (tk.TclError, ValueError):
            raise ValueError("Port muss eine Zahl sein.") from None
        return {
            "way": self.v_way.get(), "host": self.v_host.get().strip(), "port": port, "tls": self.v_tls.get(),
            "cafile": self.v_cafile.get().strip() or None, "user": self.v_user.get().strip(), "password": self.v_password.get(),
            "org": self.v_org.get().strip(), "topic": fe2.topic(self.v_prefix.get(), self.v_org.get()),
            "backend": self.v_backend.get().strip(), "admin_key": self.v_admin_key.get().strip(), "app_key": self.v_app_key.get().strip(),
        }

    @staticmethod
    def deliver(envelope: dict, connection: dict[str, Any]) -> str:
        """Sendet eine Nachricht (läuft im Hintergrund)."""
        if not connection["org"]:
            raise ValueError("Bitte die Organisation angeben.")
        if connection["way"] == "mqtt":
            publish_once(
                connection["topic"], fe2.to_json(envelope),
                host=connection["host"], port=connection["port"], username=connection["user"], password=connection["password"],
                use_tls=connection["tls"], cafile=connection["cafile"],
            )
            return f"an {connection['topic']} ({connection['host']}:{connection['port']}) gesendet"
        answer = send_raw(connection["backend"], connection["admin_key"], connection["org"], envelope)
        return f"Backend: {answer.get('message', answer)}"

    def _send(self, envelope: dict, description: str) -> None:
        if self.busy:
            self.log("Es wird noch gesendet …", "warn")
            return
        try:
            connection = self._connection()
        except ValueError as error:
            self.log(str(error), "error")
            return
        self._set_busy(True, f"Sende {description} …")

        def work() -> None:
            try:
                result = self.deliver(envelope, connection)
                self.events.put(("sent", (envelope, description, result)))
            except (MqttError, BackendError, ValueError, OSError) as error:
                self.events.put(("error", f"{description}: {error}"))
            finally:
                self.events.put(("idle", None))

        threading.Thread(target=work, daemon=True).start()

    def send_new(self) -> None:
        number = self.v_number.get().strip()
        if not number or number in self.sent:
            self.v_number.set(fe2.new_number())
            # Neue Fahrzeuge bekommen jetzt ihre Alarmierungszeit.
            for vehicle in self.vehicles:
                vehicle["alarmedTime"] = fe2.now_ms()
        try:
            envelope = self.form_envelope()
        except ValueError as error:
            self.log(str(error), "error")
            return
        self._send(envelope, f"neuer Einsatz {envelope['data']['externalId']} ({envelope['data'].get('keyword', '')})")

    def send_update(self) -> None:
        try:
            envelope = self.form_envelope()
        except ValueError as error:
            self.log(str(error), "error")
            return
        number = envelope["data"]["externalId"]
        hint = "" if number in self.sent else " – Nummer war noch nicht gesendet, wird also neu angelegt"
        self._send(envelope, f"Änderung zu {number}{hint}")

    def quick_change(self, change: str) -> None:
        try:
            envelope = fe2.apply_change(self.form_envelope(), change)
        except ValueError as error:
            self.log(str(error), "error")
            return
        self.load_envelope(envelope)
        self._send(envelope, f"{fe2.CHANGES[change]} ({envelope['data']['externalId']})")

    def send_close(self) -> None:
        number = self.v_number.get().strip()
        if not number:
            self.log("Keine Einsatznummer.", "error")
            return
        self._send(fe2.close_message(number, sender=self.v_sender.get() or "FE2-Simulator"), f"CLOSE {number}")

    def send_status(self) -> None:
        selection = self.vehicle_tree.selection()
        vehicle = self.vehicles[int(selection[0])] if selection else (self.vehicles[0] if self.vehicles else None)
        if vehicle is None:
            self.log("Kein Fahrzeug im Einsatz (Reiter „Fahrzeuge“).", "error")
            return
        name = vehicle.get("radioName") or vehicle.get("name", "")
        self._send(fe2.status_message(name, self.v_status_code.get() or "3", sender=self.v_sender.get() or "FE2-Simulator"),
                   f"Status {self.v_status_code.get()} für {name} (Backend ignoriert Status, E110)")

    def send_json(self) -> None:
        try:
            envelope = json.loads(self.json_text.get("1.0", "end"))
        except json.JSONDecodeError as error:
            self.log(f"JSON ungültig: {error}", "error")
            return
        if not isinstance(envelope, dict):
            self.log("JSON-Objekt erwartet.", "error")
            return
        self._send(envelope, f"eigenes JSON ({envelope.get('type', '?')})")

    def refresh_json(self) -> None:
        try:
            text = fe2.to_json(self.form_envelope(), pretty=True)
        except ValueError as error:
            text = f"// {error}"
        self.json_text.delete("1.0", "end")
        self.json_text.insert("1.0", text)

    def json_to_form(self) -> None:
        try:
            envelope = json.loads(self.json_text.get("1.0", "end"))
            self.load_envelope(envelope)
            self.log("JSON ins Formular übernommen.", "ok")
        except (json.JSONDecodeError, AttributeError) as error:
            self.log(f"JSON ungültig: {error}", "error")

    # MARK: Ablauf

    def toggle_scenario(self) -> None:
        if self.scenario_stop:
            self.scenario_stop.set()
            return
        try:
            connection = self._connection()
            pause = max(1, int(self.v_pause.get()))
            self.v_number.set(fe2.new_number())
            start = self.form_envelope()
        except (ValueError, tk.TclError) as error:
            self.log(str(error), "error")
            return
        stop = threading.Event()
        self.scenario_stop = stop
        self.scenario_button.configure(text="Stopp")
        steps = ["neu", "stichwort", "fahrzeug", "patient", "nachmeldung", "ort", "schliessen"]
        self.log(f"Ablauf startet ({len(steps)} Schritte, {pause} s Pause) mit Einsatz {start['data']['externalId']}.")

        def work() -> None:
            envelope = start
            try:
                for index, step in enumerate(steps):
                    if index and stop.wait(pause):
                        self.events.put(("log", ("Ablauf gestoppt.", "warn")))
                        return
                    if step == "neu":
                        message, title = envelope, "neuer Einsatz"
                    elif step == "schliessen":
                        message, title = fe2.close_message(envelope["data"]["externalId"], envelope.get("sender", "FE2-Simulator")), "CLOSE"
                    else:
                        envelope = fe2.apply_change(envelope, step)
                        message, title = envelope, fe2.CHANGES[step]
                    result = self.deliver(message, connection)
                    self.events.put(("sent", (message, f"Ablauf {index + 1}/{len(steps)}: {title}", result)))
                self.events.put(("log", ("Ablauf fertig.", "ok")))
            except (MqttError, BackendError, ValueError, OSError) as error:
                self.events.put(("error", f"Ablauf abgebrochen: {error}"))
            finally:
                self.events.put(("scenario-done", None))

        threading.Thread(target=work, daemon=True).start()

    # MARK: App-Sicht und Verbindungstest

    def fetch_app_view(self, quiet: bool = False) -> None:
        try:
            connection = self._connection()
        except ValueError as error:
            self.log(str(error), "error")
            return
        if not connection["app_key"]:
            if not quiet:
                self.log("Für die App-Sicht den App-Schlüssel eintragen (Verwaltungsseite des Backends › Organisation).", "warn")
            return

        def work() -> None:
            try:
                alarms = app_alarms(connection["backend"], connection["app_key"])
                self.events.put(("app-view", alarms))
            except BackendError as error:
                self.events.put(("app-error", str(error)))

        threading.Thread(target=work, daemon=True).start()

    def _render_app_view(self, alarms: list[dict]) -> None:
        self.app_tree.delete(*self.app_tree.get_children())
        for alarm in alarms:
            data = alarm.get("data", {})
            updated = alarm.get("updatedAt", "")
            try:
                updated = datetime.fromisoformat(updated.replace("Z", "+00:00")).astimezone().strftime("%H:%M:%S")
            except ValueError:
                pass
            self.app_tree.insert("", "end", text=alarm.get("externalId", ""), values=(
                data.get("keyword", ""), data.get("keyword_description", ""), alarm.get("revision", ""),
                alarm.get("source", ""), "ja" if alarm.get("isTest") else "", "ja" if alarm.get("closedAt") else "", updated,
            ))
        self.app_info.configure(text=f"{len(alarms)} Einsätze im Backend · abgerufen {datetime.now():%H:%M:%S}", foreground="")

    def _auto_refresh(self) -> None:
        if self.v_auto_app.get() and self.v_app_key.get().strip():
            self.fetch_app_view(quiet=True)
        self.root.after(5000, self._auto_refresh)

    def test_connection(self) -> None:
        try:
            connection = self._connection()
        except ValueError as error:
            self.log(str(error), "error")
            return
        self.save_settings()
        self._set_busy(True, "Teste Verbindung …")

        def work() -> None:
            try:
                if connection["way"] == "mqtt" or connection["host"]:
                    try:
                        with MqttConnection(connection["host"], connection["port"], connection["user"], connection["password"],
                                            use_tls=connection["tls"], cafile=connection["cafile"]):
                            pass
                        self.events.put(("log", (f"MQTT: Anmeldung bei {connection['host']}:{connection['port']} als „{connection['user']}“ klappt.", "ok")))
                    except MqttError as error:
                        self.events.put(("log", (f"MQTT: {error}", "error")))
                if connection["backend"] and connection["admin_key"]:
                    try:
                        status = admin_status(connection["backend"], connection["admin_key"])
                        mqtt = status.get("mqtt", {})
                        state = "verbunden" if mqtt.get("connected") else ("aus" if not mqtt.get("enabled") else f"nicht verbunden ({mqtt.get('lastError') or '?'})")
                        self.events.put(("log", (f"Backend {status.get('version')}: MQTT {state}, Debug {'an' if status.get('debugEnabled') else 'aus'}, "
                                                 f"{status.get('organisations')} Organisation(en), {status.get('alarms')} Einsätze.", "ok")))
                    except BackendError as error:
                        self.events.put(("log", (f"Backend (Verwaltung): {error}", "error")))
                if connection["backend"] and connection["app_key"]:
                    try:
                        ping = app_ping(connection["backend"], connection["app_key"])
                        ok = ping.get("organisationId") == connection["org"]
                        text = f"App-Schlüssel gehört zu „{ping.get('organisationName')}“ ({ping.get('organisationId')})"
                        self.events.put(("log", (text + ("." if ok else f" – passt nicht zur Organisation „{connection['org']}“!"), "ok" if ok else "warn")))
                    except BackendError as error:
                        self.events.put(("log", (f"App-Schlüssel: {error}", "error")))
            finally:
                self.events.put(("idle", None))

        threading.Thread(target=work, daemon=True).start()

    # MARK: Hilfen

    def log(self, text: str, tag: str = "") -> None:
        self.log_text.configure(state="normal")
        self.log_text.insert("end", f"{datetime.now():%H:%M:%S}  ", "time")
        self.log_text.insert("end", text + "\n", tag)
        self.log_text.see("end")
        self.log_text.configure(state="disabled")

    def _set_busy(self, busy: bool, text: str = "Bereit.") -> None:
        self.busy = busy
        self.v_status.set(text)
        for button in self.action_buttons:
            button.state(["disabled"] if busy else ["!disabled"])

    def _drain_events(self) -> None:
        try:
            while True:
                kind, payload = self.events.get_nowait()
                if kind == "sent":
                    envelope, description, result = payload
                    self._record(envelope)
                    self.log(f"{description}: {result}", "ok")
                    if self.v_number.get() == envelope.get("data", {}).get("externalId") and envelope.get("type") == "ALARM":
                        self.load_envelope(envelope)
                    if self.v_app_key.get().strip():
                        self.root.after(800, lambda: self.fetch_app_view(quiet=True))
                elif kind == "error":
                    self.log(payload, "error")
                elif kind == "log":
                    self.log(*payload)
                elif kind == "idle":
                    self._set_busy(False)
                elif kind == "scenario-done":
                    self.scenario_stop = None
                    self.scenario_button.configure(text="Abspielen")
                elif kind == "app-view":
                    self._render_app_view(payload)
                elif kind == "app-error":
                    self.app_info.configure(text=payload, foreground="#d0021b")
        except queue.Empty:
            pass
        self.root.after(100, self._drain_events)

    def _update_way(self) -> None:
        state = ["!disabled"] if self.v_way.get() == "mqtt" else ["disabled"]
        for child in self.mqtt_row.winfo_children():
            if isinstance(child, (ttk.Entry, ttk.Spinbox, ttk.Checkbutton, ttk.Button)):
                child.state(state)

    def _tls_changed(self) -> None:
        try:
            port = int(self.v_port.get())
        except (tk.TclError, ValueError):
            return
        if self.v_tls.get() and port == 1883:
            self.v_port.set(8883)
        elif not self.v_tls.get() and port == 8883:
            self.v_port.set(1883)

    def _choose_cafile(self) -> None:
        path = filedialog.askopenfilename(title="CA-Zertifikat des Brokers", filetypes=[("Zertifikat", "*.pem *.crt *.cer"), ("Alle", "*")])
        if path:
            self.v_cafile.set(path)

    def _tab_changed(self) -> None:
        current = self.notebook.select()
        if current == str(self.json_tab):
            self.refresh_json()
        elif current == str(self.app_tab):
            self.fetch_app_view(quiet=True)


def main() -> None:
    root = tk.Tk(className=APP_NAME)
    style = ttk.Style(root)
    if not IS_MAC and "clam" in style.theme_names():
        style.theme_use("clam")
    simulator = Simulator(root)
    if IS_MAC:
        # Cmd-Q speichert Einstellungen wie das Schließen des Fensters.
        root.createcommand("tk::mac::Quit", simulator.quit)
    simulator.log("Bereit. Vorlage wählen oder Formular ausfüllen, dann „Als neuen Einsatz senden“.")
    root.mainloop()


if __name__ == "__main__":
    main()
