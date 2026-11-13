# FE2-Simulator unter macOS starten

Mit dem FE2-Simulator spielst du Alamos FE2 nach, ohne eine echte FE2-Instanz zu brauchen. Er
schickt Einsätze genau so, wie es FE2 mit JSON-Plugin (Datenformat V2) und MQTT-Plugin tut, an
den Broker. Von dort holt das ELRD-Backend sie ab, und die App auf dem iPad zeigt sie an.

```
FE2-Simulator ──MQTT──▶ Mosquitto ──▶ ELRD-Backend ◀──HTTP── ELRD-App (iPad / Simulator)
   (dieser Mac)          (Docker)        (Docker)
```

Was du damit machen kannst:

- Einsätze frei zusammenstellen (Stichwort, Meldebild, Alarmtext, Ort mit Koordinate, Anrufer,
  Fahrzeuge, Patienten) oder aus vier Vorlagen laden
- als neuen Einsatz senden oder als Änderung (gleiche Einsatznummer)
- mit einem Klick ändern, wie es die Leitstelle tun würde: Stichwort erhöhen, Fahrzeug
  nachalarmieren, Patient hinzufügen, Nachmeldung, Ort korrigieren
- Einsätze schließen (`CLOSE`) und Fahrzeugstatus senden
- einen ganzen Ablauf mit Pausen abspielen
- im Reiter **JSON** die Nachricht sehen und von Hand verändert senden
- im Reiter **App-Sicht** prüfen, was die App vom Backend bekommt

## 1. Einmalig: Python mit Tk installieren

Der Simulator braucht **Python 3.9 oder neuer mit Tk 8.6**, sonst keine Zusatzpakete. Das
Python, das macOS mitbringt (`/usr/bin/python3`), ist ungeeignet: Es hat nur Tk 8.5, und die
Fenster werden fehlerhaft gezeichnet.

**Weg A – Homebrew (empfohlen).** Falls Homebrew fehlt, die Zeile von <https://brew.sh> ins
Terminal kopieren. Dann:

```sh
brew install python python-tk
```

**Weg B – python.org.** Den Installer von <https://www.python.org/downloads/macos/> nehmen (Tk
ist dabei). Danach einmal im Finder unter *Programme › Python 3.x* **„Install
Certificates.command“** doppelklicken. Ohne diesen Schritt scheitern Verbindungen mit TLS an
der Zertifikatsprüfung.

Prüfen (im Terminal):

```sh
python3 -c "import tkinter; print(tkinter.TkVersion)"   # muss 8.6 oder höher zeigen
```

## 2. Broker und Backend starten

Am einfachsten mit **Docker Desktop** (<https://www.docker.com/products/docker-desktop/>). Im
Terminal, im Ordner des ELRD-Projekts:

```sh
cd backend
./mosquitto/dev-passwd.sh                          # einmalig: Testbenutzer für den Broker
docker compose -f docker-compose.dev.yml up --build
```

Das Fenster offen lassen. Zum Beenden drückst du `Ctrl-C`.

Danach im Browser <http://localhost:8080> öffnen und mit dem Admin-Schlüssel
`entwicklung-admin-schluessel` anmelden. Unter **Organisationen** legst du an:

- Kennung **`test-rd`**
- Name z. B. „Test RD“

Den angezeigten **App-Schlüssel** (`elrd_…`) kopieren. Er wird nur dieses eine Mal angezeigt;
sonst später „neuer Schlüssel“ wählen.

> Die Testbenutzer aus `dev-passwd.sh`: Broker-Benutzer `test-rd`, Passwort `entwicklung-fe2`.
> Der Simulator hat diese Werte schon voreingestellt. Sie sind nur für den eigenen Rechner gedacht.

## 3. Simulator starten

**Per Doppelklick:** Im Finder `tools/alamos/FE2-Simulator.command` doppelklicken. Der Starter
sucht selbst das passende Python.

> Meldet macOS beim ersten Mal „kann nicht geöffnet werden, da es von einem nicht
> verifizierten Entwickler stammt“: Rechtsklick auf die Datei › **Öffnen** › **Öffnen**. Ab
> dann klappt der Doppelklick. Hast du das Projekt als ZIP geladen und die Datei ist nicht
> ausführbar, hilft einmal `chmod +x tools/alamos/FE2-Simulator.command` im Terminal.

**Per Terminal:**

```sh
cd tools/alamos
python3 fe2_simulator.py
```

## 4. Erster Test

1. **Verbindung:** Die Voreinstellungen passen zur Entwicklungsumgebung aus Schritt 2:
   - Weg „MQTT wie FE2“
   - Broker `localhost`, Port `1883`, ohne TLS
   - Benutzer `test-rd`
   - Organisation `test-rd`
   - Backend `http://localhost:8080`

   Bei **App-Schlüssel** den kopierten Schlüssel einfügen und **Verbindung testen** klicken.
   Im Protokoll sollten drei grüne Zeilen stehen: MQTT, Backend und App-Schlüssel.
2. Links bei **Neuer Einsatz aus Vorlage** z. B. „vu“ wählen, **Laden** und dann
   **▶ Als neuen Einsatz senden** klicken.
3. Im Reiter **App-Sicht** erscheint der Einsatz nach etwa einer Sekunde. Er aktualisiert sich
   alle 5 Sekunden.
4. Änderungen ausprobieren, etwa **Stichwort erhöhen** oder **Fahrzeug nachalarmieren**. In
   der App-Sicht steigt der „Stand“.
5. Oder unten **Ablauf › Abspielen**: neuer Einsatz → Stichwort → Fahrzeug → Patient →
   Nachmeldung → Ort → CLOSE, mit einstellbarer Pause.

Eigene Einsätze stellst du so zusammen:

- Felder im Reiter **Einsatz** ändern; Fahrzeuge und Patienten in ihren eigenen Reitern.
- **⟳ Änderung senden** schickt das Formular mit derselben Einsatznummer, also als
  Aktualisierung.
- **▶ Als neuen Einsatz senden** vergibt eine neue Nummer, sobald die aktuelle schon gesendet
  wurde.
- Ein Klick auf einen Einsatz in der Liste links lädt ihn zum Weiterbearbeiten.

## 5. Mit der App auf dem iPad verbinden

1. Mac und iPad ins **gleiche WLAN**.
2. IP-Adresse des Macs herausfinden:
   ```sh
   ipconfig getifaddr en0      # z. B. 192.168.178.23
   ```
3. In der App: **Einstellungen › Alamos FE2**
   - „Einsätze aus Alamos FE2 abrufen“ einschalten
   - Adresse `http://192.168.178.23:8080` (ohne HTTPS geht das nur im lokalen Netz)
   - den App-Schlüssel eintragen, **Schlüssel speichern**, dann **Verbindung testen**
   - Fragt iPadOS nach dem Zugriff auf das lokale Netzwerk: **Erlauben**
4. Im Simulator einen Einsatz senden. Nach spätestens 30 Sekunden (Abfragetakt, einstellbar)
   erscheint er oben in der Einsatzliste mit „Neu“. Dann **Als Einsatz übernehmen**.

Im **iOS-Simulator von Xcode** auf demselben Mac genügt die Adresse `http://localhost:8080`.

Blockiert die macOS-Firewall die Verbindung (*Systemeinstellungen › Netzwerk › Firewall*),
musst du dort eingehende Verbindungen für Docker erlauben.

## 6. Andere Wege und echte Broker

- **HTTP direkt ins Backend (Debug):** Die Nachricht geht ohne Broker in die Schublade. Das ist
  praktisch, wenn kein Broker läuft. Dafür braucht es den Admin-Schlüssel, und im Backend muss
  `Elrd:Debug:Enabled` eingeschaltet sein.
- **Echter Broker mit TLS:** Broker-Adresse, Port `8883`, **TLS** anhaken, Benutzer und Passwort
  der Organisation eintragen. Bei einem selbst signierten Zertifikat unter **CA-Datei** die
  `.pem`-Datei der eigenen Zertifizierungsstelle auswählen.
- **Fahrzeugstatus:** wird gesendet wie von FE2, vom Backend aber bewusst nicht verarbeitet
  (E110). Damit lässt sich prüfen, dass Statusmeldungen nichts durcheinanderbringen.

Ohne Oberfläche gibt es dasselbe im Terminal: `./testalarm.py --help`.

## 7. Wo der Simulator etwas speichert

- Einstellungen: `~/Library/Application Support/ELRD FE2-Simulator/einstellungen.json`
  (ohne Passwörter)
- Gesendete Einsätze: im selben Ordner, `einsaetze.json`
- Passwort, Admin- und App-Schlüssel: im **Schlüsselbund** unter „ELRD FE2-Simulator“, wenn
  „Zugangsdaten im Schlüsselbund merken“ angehakt ist; sonst gar nicht

## 8. Wenn etwas nicht klappt

| Meldung | Lösung |
|---|---|
| `tkinter fehlt` / Fenster bleibt leer | Python mit Tk installieren (Schritt 1), über `FE2-Simulator.command` starten |
| `Broker localhost:1883 nicht erreichbar` | Läuft `docker compose … up` noch? Docker Desktop gestartet? |
| `Anmeldung abgelehnt – Benutzername oder Passwort falsch …` | `./mosquitto/dev-passwd.sh` ausführen und den Broker-Container neu starten |
| Gesendet, aber nichts in der App-Sicht | Organisation `test-rd` im Backend angelegt? Topic muss `elrd/test-rd/alarm` heißen; Benutzer = Organisation (Rechte im Broker) |
| `Schlüssel abgelehnt (401)` | App-Schlüssel neu erzeugen (Verwaltungsseite › neuer Schlüssel) und eintragen |
| `Nicht gefunden (404)` beim HTTP-Weg | Organisation fehlt oder Debug im Backend ausgeschaltet |
| `Zertifikat des Brokers ungültig` | python.org-Python: „Install Certificates.command“ ausführen; eigene CA unter „CA-Datei“ angeben |
| App findet das Backend nicht | Gleiches WLAN? IP richtig? `http://` statt `https://`? Lokales Netzwerk in iPadOS erlaubt? |
