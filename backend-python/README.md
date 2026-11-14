# ELRD-Backend in Python – auf dem MacBook ohne Zusatzsoftware

Das ist das ELRD-Backend als **reines Python**. Es läuft mit dem Python, das auf dem Mac
schon dabei ist; Docker, .NET und Mosquitto brauchst du nicht. Den **MQTT-Broker bringt es
selbst mit**.

```
Alamos FE2 / FE2-Simulator ──MQTT──▶ ┌─────── ELRD-Backend (Python) ───────┐ ◀──HTTP── ELRD-App
                                     │ eingebauter Broker → Schublade → API │
                     Browser ──────▶ │ Verwaltung & Debug: Testeinsätze      │
                                     └──────────────────────────────────────┘
```

Es hat dieselbe Schnittstelle wie das .NET-Backend in `backend/`. App, FE2-Simulator,
`testalarm.py` und die Verwaltungsseite funktionieren mit beiden.

| | Python (dieser Ordner) | .NET (`backend/`) |
|---|---|---|
| Braucht | Python 3.9+ (auf dem Mac vorhanden) | Docker oder .NET 10, dazu Mosquitto |
| MQTT-Broker | eingebaut (Benutzer = Organisation) | Mosquitto (eigene Benutzerverwaltung) |
| Gedacht für | Testen auf dem Mac, kleiner Betrieb im eigenen Netz | Server oder Hoster |
| Speicherung | `daten/store.json` (Mac: FileVault) | `store.json`, optional verschlüsselt |

## 1. Python prüfen (einmalig)

Im **Terminal** (*Programme › Dienstprogramme › Terminal*):

```sh
python3 --version
```

Bei **3.9 oder höher** passt alles. Öffnet sich stattdessen ein Fenster „Befehlszeilen-
Entwicklerwerkzeuge installieren“: auf **Installieren** klicken; die Werkzeuge sind auch für
Xcode nötig. Alternativ geht `brew install python`.

## 2. Starten

**Per Doppelklick:** Im Finder im ELRD-Projekt `backend-python/ELRD-Backend.command`
doppelklicken. Es öffnet sich ein Terminal-Fenster, in dem das Backend läuft.

> Beim ersten Mal meldet macOS evtl. „nicht verifizierter Entwickler“: Rechtsklick › **Öffnen** ›
> **Öffnen**. Fragt macOS, ob „python3“ **eingehende Verbindungen** annehmen darf: **Erlauben**.
> Sonst erreicht das iPad den Mac nicht.

**Per Terminal:**

```sh
cd backend-python
python3 elrd_server.py
```

Beim **ersten Start** erscheint so etwas:

```
 ELRD-Backend (Python) 0.1.0-py läuft
 Verwaltung & Debug:  http://localhost:8080
 Adresse für die App: http://192.168.178.23:8080
 Admin-Schlüssel:     entwicklung-admin-schluessel
 MQTT-Broker:         192.168.178.23:1883 (eingebaut)
 Erster Start – Organisation „test-rd“ angelegt:
   App-Schlüssel:     elrd_AbC…                ← in der App eintragen (nur jetzt sichtbar)
   MQTT für FE2:      Benutzer test-rd, Passwort entwicklung-fe2
```

Den **App-Schlüssel** gleich kopieren. Verlegt? Auf der Verwaltungsseite bei der Organisation
„neuer Schlüssel“ wählen.

Beenden mit `Ctrl-C` oder durch Schließen des Terminal-Fensters. Einsätze und Organisationen
bleiben in `backend-python/daten/` erhalten.

## 3. Einsätze an die App schicken

### Direkt (ohne FE2)

1. Im Browser <http://localhost:8080> öffnen und mit dem Admin-Schlüssel anmelden.
2. Unter **Testeinsätze** die Organisation `test-rd` wählen und beim Weg „direkt in die
   Schublade“ oder „über den MQTT-Broker“ eine der Vorlagen anklicken, z. B. **+ RD 2 …**.
3. Am Einsatz unten lassen sich Änderungen simulieren:
   - Stichwort erhöhen
   - Fahrzeug nachalarmieren
   - Patient hinzufügen
   - Nachmeldung
   - Ort korrigieren
   - Einsatz schließen

   Unter „Eigenes JSON“ kannst du außerdem beliebige FE2-Nachrichten einspielen.

### Wie FE2 (über MQTT)

- **FE2-Simulator mit Oberfläche:** `tools/alamos/FE2-Simulator.command`, siehe
  `tools/alamos/ANLEITUNG-macOS.md`. Die Voreinstellungen passen ohne Änderung: `localhost:1883`,
  Benutzer `test-rd`, Passwort `entwicklung-fe2`, Backend `http://localhost:8080`.
- **Terminal:** `tools/alamos/testalarm.py senden vu`
- **Echtes FE2:** Im MQTT-Plugin trägst du ein:
  - Broker `tcp://<IP des Macs>:1883`
  - Benutzer = Kennung der Organisation, dazu ihr MQTT-Passwort
  - Topic `elrd/<organisation>/alarm`

  Das JSON-Plugin davor stellst du auf Datenformat **V2**, ohne Passwort.

### In der App

**Einstellungen › Alamos FE2:**
- Abruf einschalten
- Adresse `http://<IP des Macs>:8080` (steht beim Start unter „Adresse für die App“)
- App-Schlüssel eintragen
- **Verbindung testen**

Mac und iPad müssen im **gleichen WLAN** sein (oder per Tailscale/VPN verbunden; dann die Tailscale-IP des Macs mit `http://` eintragen). Im iOS-Simulator von Xcode genügt
`http://localhost:8080`.

## 4. Organisationen und Zugänge

Auf der Verwaltungsseite unter **Organisationen**:

- **Anlegen:** zeigt einmalig den **App-Schlüssel** und das **MQTT-Passwort**. Der
  MQTT-Benutzer ist die Kennung der Organisation.
- **neuer Schlüssel** / **neues MQTT-Passwort:** Der alte Zugang gilt sofort nicht mehr.
- Jede Organisation darf nur auf ihr eigenes Topic `elrd/<kennung>/alarm` senden; alles
  andere verwirft der Broker.

Gespeichert werden nur Hashes, nie die Schlüssel selbst.

## 5. Einstellungen (`daten/einstellungen.json`)

Die Datei wird beim ersten Start angelegt. Nach einer Änderung das Backend neu starten.

| Eintrag | Standard | Bedeutung |
|---|---|---|
| `http.port` | `8080` | Port für App und Verwaltung |
| `admin_schluessel` | `entwicklung-admin-schluessel` | **ändern**, sobald andere im Netz mitlesen könnten (mind. 16 Zeichen) |
| `debug` | `true` | Testeinsätze und Simulation |
| `aufbewahrung_stunden` | `24` | Einsätze so lange nach der letzten Änderung behalten |
| `topic_praefix` | `elrd` | Topics `elrd/<organisation>/alarm` |
| `broker.port` | `1883` | Port des eingebauten Brokers |
| `broker.tls_port`, `zertifikat`, `schluessel` | – | optional MQTT mit TLS (z. B. 8883, PEM-Dateien) |
| `externer_broker.eingeschaltet` … | `false` | statt/zusätzlich: Einsätze bei einem externen Broker abholen (`host`, `port`, `tls`, `benutzer`, `passwort`, `ca_datei`) |

Für einen einzelnen Start gehen auch Startoptionen:
- `--http-port 9000`, `--mqtt-port 1884` (wenn ein Port belegt ist)
- `--nur-lokal` (nur von diesem Mac erreichbar)
- `--ohne-broker`
- `--daten <ordner>`
- `--ausfuehrlich` (jede HTTP-Anfrage protokollieren)

## 6. Wenn etwas nicht klappt

| Meldung / Problem | Lösung |
|---|---|
| `HTTP-Port 8080 ist belegt` | Läuft das Backend schon (anderes Fenster) oder Docker? Sonst `--http-port 9000` |
| `MQTT-Port 1883 ist belegt` | Mosquitto (`brew services stop mosquitto`) oder Docker-Backend beenden, oder `--mqtt-port 1884` |
| iPad erreicht den Mac nicht | gleiches WLAN? IP aus „Adresse für die App“? Firewall-Abfrage erlaubt? Lokales Netzwerk in iPadOS erlaubt? |
| App meldet „iPadOS erlaubt für diese Adresse nur https://“ | `http://` geht nur zu privaten Adressen (192.168.…, 10.…, 172.16–31.…), Tailscale (100.64–127.…), `….local` oder Namen ohne Punkt; ältere App-Versionen kannten Tailscale noch nicht |
| `HTTPS-Anfrage … auf dem HTTP-Port` | in der App die Adresse mit `http://` eintragen (z. B. `http://192.168.178.23:8080`); neuere App-Versionen ergänzen bei IP-Adressen selbst `http://` |
| `Anmeldung abgelehnt` beim Senden | MQTT-Benutzer = Kennung der Organisation, Passwort von der Verwaltungsseite |
| Gesendet, aber kein Einsatz | Topic muss `elrd/<eigene-kennung>/alarm` sein (steht im Backend-Fenster als Warnung) |
| `Verwaltungsseite fehlt` | Backend aus dem ELRD-Projektordner starten (die Seite liegt in `backend/src/ELRD.Backend/wwwroot`) |

## Für Entwickler

- Aufbau: `elrd_server.py` (Start, Einstellungen) und `elrd/`:
  - `store.py`: Datei
  - `organisations.py`
  - `ingest.py`: FE2-Format V2
  - `broker.py`: eingebauter MQTT-3.1.1-Broker
  - `bridge.py`: externer Broker
  - `web.py`: HTTP

  Gemeinsam mit den Werkzeugen genutzt werden `tools/alamos/fe2_format.py` (Vorlagen,
  Änderungen) und `mqtt_client.py`.
- Tests: `python3 -m unittest -v test_server` (mit externem Broker zusätzlich
  `ELRD_TEST_MQTT_BRIDGE=host:port:benutzer:passwort`). Sie laufen in der CI mit Python 3.9.
- `daten/store.json` hat dasselbe Format wie beim .NET-Backend (gleiche Schlüssel-Hashes).
