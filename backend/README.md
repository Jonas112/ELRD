# ELRD-Backend – Datenschublade für Alamos FE2

Das Backend nimmt Einsätze aus **Alamos FE2** entgegen und hält sie für die
**ELRD-App** bereit. Mehr macht es nicht: keine Einsatzführung, kein Archiv. Was die
App übernimmt, wird dort dokumentiert. Im Backend wird der Einsatz nach einer
einstellbaren Zeit gelöscht (Standard 24 h nach der letzten Änderung).

```
Alamos FE2 ──JSON-Plugin (V2) + MQTT-Plugin──▶ MQTT-Broker ──▶ ELRD-Backend ◀──HTTPS── ELRD-App
                                              (Mosquitto)      (diese App)     (fragt regelmäßig nach)
```

- **.NET 10**, ASP.NET Core Minimal API, **keine NuGet-Pakete** (E123): eigener kleiner
  MQTT-3.1.1-Client, Speicherung als JSON-Datei (optional mit AES-GCM verschlüsselt).
- Läuft als Container, auf jedem Linux- oder Windows-Server mit .NET 10 oder bei
  Hostern wie Azure App Service.
- **Debug-Seite** unter `/`: Organisationen verwalten, Testeinsätze anlegen,
  Änderungen simulieren (Stichwort, Patient, Fahrzeug, Ort, Schließen), eigenes JSON
  einspielen – direkt oder über den Broker (ganze Kette).

> **Nur auf dem Mac testen?** `backend-python/` ist dasselbe Backend in reinem Python mit
> eingebautem MQTT-Broker – ohne Docker, .NET oder Mosquitto (siehe `backend-python/README.md`).

## Schnellstart auf dem eigenen Rechner

Mit Docker:

```sh
cd backend
./mosquitto/dev-passwd.sh                       # Testbenutzer für den Broker
docker compose -f docker-compose.dev.yml up --build
```

Ohne Docker (.NET 10 SDK und Mosquitto installiert, z. B. `brew install mosquitto dotnet`):

```sh
cd backend
./mosquitto/dev-passwd.sh
mosquitto -c mosquitto/mosquitto.dev.conf       # Pfade in der Datei ggf. auf ./mosquitto anpassen
cd src/ELRD.Backend && dotnet run               # nutzt appsettings.Development.json
```

Dann <http://localhost:8080> (Docker) bzw. die von `dotnet run` genannte Adresse öffnen,
mit dem Admin-Schlüssel `entwicklung-admin-schluessel` anmelden und:

1. Organisation **`test-rd`** anlegen (passt zum Broker-Benutzer aus `dev-passwd.sh`).
   Den angezeigten **App-Schlüssel** kopieren.
2. In der App: Einstellungen › **Alamos FE2** › Adresse `http://<Rechner-IP>:8080`,
   App-Schlüssel einfügen, „Verbindung testen“.
3. Auf der Debug-Seite „+ RD 2 …“ antippen – der Einsatz erscheint in der App.
   Oder mit dem Skript `tools/alamos/send-test-alarm.sh` wie FE2 über den Broker senden.

> Ohne HTTPS erlaubt die App nur Adressen im lokalen Netz (`NSAllowsLocalNetworking`;
> iOS fragt beim ersten Mal nach dem Zugriff aufs lokale Netzwerk). Im Betrieb immer HTTPS.

## Einstellungen

Alle Werte stehen in `appsettings.json` und lassen sich per Umgebungsvariable
überschreiben (`:` wird zu `__`, z. B. `Elrd__Admin__Key`).

| Einstellung | Standard | Bedeutung |
|---|---|---|
| `Elrd:Admin:Key` | – | Schlüssel für Verwaltung und Debug-Seite (mind. 16 Zeichen). Ohne Schlüssel ist beides gesperrt. |
| `Elrd:Debug:Enabled` | `false` | Testeinsätze und Simulationen. Im Betrieb aus. |
| `Elrd:Mqtt:Enabled` | `false` | Broker-Verbindung. |
| `Elrd:Mqtt:Host` / `Port` / `UseTls` | `localhost` / `8883` / `true` | Broker-Adresse. |
| `Elrd:Mqtt:Username` / `Password` | – | Zugang des Backends zum Broker. |
| `Elrd:Mqtt:TopicPrefix` | `elrd` | Topics: `elrd/<organisation>/alarm`. |
| `Elrd:Mqtt:AllowUntrustedCertificates` | `false` | Nur für Tests mit selbst signiertem Zertifikat. |
| `Elrd:Storage:DataDirectory` | `data` | Ordner für `store.json`. |
| `Elrd:Storage:EncryptionKey` | – | 32 Byte Base64 (`openssl rand -base64 32`) → Datei verschlüsselt. |
| `Elrd:Retention:Hours` | `24` | Einsätze so lange nach der letzten Änderung behalten. |

## Betrieb auf einem eigenen Server (empfohlen)

Ein kleiner Linux-Server (z. B. 2 GB RAM) mit Docker reicht. Beispiel mit Domain
`elrd.example.de` für das Backend und `mqtt.example.de` für den Broker:

1. **Repository holen**, in `backend/` wechseln.
2. **`.env`** aus `.env.beispiel` anlegen: Admin-Schlüssel, Broker-Passwort des
   Backends, Verschlüsselungsschlüssel. `Elrd__Debug__Enabled=false`.
3. **Broker-Benutzer** anlegen (Benutzername der Organisation = ihre Kennung, das
   erzwingt die ACL in `mosquitto/acl`):
   ```sh
   touch mosquitto/passwd
   docker run --rm -v "$PWD/mosquitto:/w" eclipse-mosquitto:2 mosquitto_passwd -b /w/passwd elrd-backend '<passwort-backend>'
   docker run --rm -v "$PWD/mosquitto:/w" eclipse-mosquitto:2 mosquitto_passwd -b /w/passwd brk-schweinfurt '<passwort-fe2>'
   chmod 644 mosquitto/passwd
   ```
4. **TLS-Zertifikat** für `mqtt.example.de` (z. B. `certbot certonly --standalone -d mqtt.example.de`)
   nach `mosquitto/certs/fullchain.pem` und `privkey.pem` kopieren (nach jeder
   Verlängerung erneut, dann `docker compose restart mosquitto`).
5. `docker compose up -d --build`
6. **HTTPS für das Backend** mit einem Reverse Proxy, z. B. Caddy (holt das Zertifikat selbst):
   ```
   elrd.example.de {
       reverse_proxy 127.0.0.1:8080
   }
   ```
7. Firewall: nur 443 (Caddy) und 8883 (MQTT/TLS) öffnen.
8. `https://elrd.example.de` öffnen, mit Admin-Schlüssel anmelden, Organisation
   `brk-schweinfurt` anlegen, App-Schlüssel an die Nutzer geben.

## Betrieb bei einem Hoster (ohne eigenen Broker)

Das Backend ist eine normale ASP.NET-Core-App und läuft z. B. auf **Azure App
Service (Linux, .NET 10)**, Render, Fly.io oder als Container bei jedem Anbieter:

- Veröffentlichen: `dotnet publish src/ELRD.Backend -c Release -o out` (oder Dockerfile).
- Einstellungen als Umgebungsvariablen setzen (siehe Tabelle).
- `Elrd__Storage__DataDirectory` auf einen **dauerhaften** Speicher legen
  (Azure: `/home/data`). Sonst gehen Organisationen beim Neustart verloren.
- **Genau eine Instanz** betreiben (keine automatische Skalierung) – der Speicher
  ist eine Datei.
- Broker: gehosteter MQTT-Dienst mit TLS und Benutzern/ACL (z. B. HiveMQ Cloud,
  EMQX Cloud). Topics und Rechte wie in `mosquitto/acl`.

## Organisation anlegen und FE2 anbinden

1. Debug-/Verwaltungsseite → **Organisation anlegen** (Kennung z. B. `brk-schweinfurt`).
   Der **App-Schlüssel** wird einmal angezeigt (gespeichert ist nur sein SHA-256).
2. Broker-Benutzer `brk-schweinfurt` mit eigenem Passwort anlegen (siehe oben).
3. In **FE2** (Admin der Organisation) eine eigene Einheit „ELRD-Export“ anlegen und
   aus den Einheiten, die ELRD bekommen sollen, mit „Einheiten alarmieren“ auslösen.
   Grund: Das JSON-Plugin ersetzt den Alarmtext durch JSON.
4. Alarmablauf der Einheit „ELRD-Export“:

   **JSON-Plugin**

   | Feld | Wert |
   |---|---|
   | Modus | JSON in Alarmtext schreiben |
   | Version Datenformat | **V2** |
   | Passwort für Verschlüsselung | **leer** (Verfahren nicht dokumentiert, TLS schützt den Weg) |
   | Patient hinzufügen / Anrufer hinzufügen | an (ab FE2 2.27, falls gewünscht und erlaubt) |
   | Alarm protokollieren | zum Testen an |

   **MQTT-Plugin** (direkt danach)

   | Feld | Wert |
   |---|---|
   | Broker | `ssl://mqtt.example.de:8883` (falls FE2 das nicht annimmt: `tcp://…:8883` und Server-Zertifikat (CA) angeben) |
   | Benutzername / Passwort | `brk-schweinfurt` / Passwort aus Schritt 2 |
   | Topic | `elrd/brk-schweinfurt/alarm` |
   | Retained | aus |
   | Client ID | z. B. `fe2-brk-schweinfurt` |

5. In FE2 einen Probealarm auf „ELRD-Export“ auslösen. Auf der Debug-Seite steigt
   „Nachrichten empfangen“, der Einsatz steht in der Liste und erscheint in der App.

Fahrzeugstatus (`type: STATUS`) nimmt das Backend an, verarbeitet ihn aber nicht
(ELRD führt keinen FMS-Status, E110).

## Schnittstelle für die App

Anmeldung je Organisation: `Authorization: Bearer <App-Schlüssel>`. Zeitpunkte in
UTC, z. B. `2026-11-11T18:30:00.123Z`.

| Aufruf | Antwort |
|---|---|
| `GET /api/v1/ping` | `{ organisationId, organisationName, serverTime, version, retentionHours }` |
| `GET /api/v1/alarms?since=<Zeitpunkt>&includeClosed=true` | `{ serverTime, alarms: [Alarm] }` – mit `since` nur danach geänderte; `serverTime` als nächstes `since` verwenden |
| `GET /api/v1/alarms/{id}` | `Alarm` |
| `GET /health` | `{ status, version, mqtt }` (ohne Anmeldung) |

`Alarm` = `{ id, externalId, revision, receivedAt, updatedAt, closedAt, sender, source, isTest, data }`,
`data` unverändert im **Datenformat V2** der externen Schnittstelle von FE2
(`keyword`, `keyword_description`, `message[]`, `location{coordinate:[lng,lat], street, house, postalCode, city …}`,
`caller`, `patient[]`, `vehicles[]`, `units[]`, `custom`).

Verwaltung und Debug (`X-Admin-Key`): `/admin/api/status`, `/admin/api/organisations`,
`/admin/api/debug/…` – genutzt von der Seite unter `/`.

## Datenschutz

- Einsatz- und ggf. Patientendaten liegen nur bis zum Ablauf der Aufbewahrung im Backend.
- `Elrd:Storage:EncryptionKey` setzen; Server-Festplatte zusätzlich verschlüsseln.
- Protokolle enthalten nur Kennungen (Organisation, Einsatz-ID, Stand), keine Inhalte.
- Vor dem Echtbetrieb: Vertrag zur Auftragsverarbeitung mit dem FE2-Betreiber,
  Freigabe der Datenweitergabe (Leitstelle/Träger), Datenschutzkonzept.

## Tests

```sh
cd backend
dotnet run --project tests/ELRD.Backend.Tests
# mit laufendem Broker zusätzlich die MQTT-Kette:
ELRD_TEST_MQTT=localhost:1883:elrd-backend:entwicklung-backend dotnet run --project tests/ELRD.Backend.Tests
```

Die Tests kommen ohne Test-Framework aus (kleine Konsolen-App, E123). In GitHub
Actions läuft `.github/workflows/backend.yml` bei Änderungen unter `backend/`.
