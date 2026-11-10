# Synchronisation – Schnittstelle und Konfliktstrategie

Stand: Schritt 53 (November 2026). Umgesetzt in `ELRDSync` (Format, Zusammenführen, Vertrag) und `ELRDStore/Sync` (Übernahme, Abgleich). Ein Server existiert noch nicht. `InMemorySyncServer` ist die ausführbare Beschreibung des Vertrags.

## Grundsätze

- **Lokal zuerst.** Jede Änderung wird sofort auf dem Gerät gespeichert. Der Abgleich ist nie Voraussetzung: ohne Server (`LocalOnlyTransport`) arbeitet die App wie bisher.
- **Einheit ist der Einsatz.** Freigabe, Abgleich und endgültiges Löschen gelten immer für einen ganzen Einsatz (`missionID`).
- **Übertragen werden Ereignisse, nicht Datensätze.** Jede Änderung erzeugt ein `ChangeEvent`: Entität, Operation (`insert`, `update`, `delete`, `restore`), geänderte Felder, HLC-Zeitstempel und Autor. Das Journal wird nur ergänzt, nie geändert.
- **Konflikte löst das Gerät, nie der Server.** Der Server speichert und verteilt nur.

## Konfliktstrategie

| Fall | Regel |
|---|---|
| Zwei Geräte ändern verschiedene Felder | Beide Änderungen bleiben erhalten. |
| Zwei Geräte ändern dasselbe Feld | Der jüngere HLC-Zeitstempel gewinnt (bei Gleichstand die Geräte-ID, damit alle Geräte gleich entscheiden). |
| Listen mit Kennung (Verletzungen, zugeordnete Einheiten, Anhänge) | Elementweise: Hinzufügen auf Gerät A und Hinzufügen auf Gerät B ergibt beide Elemente. Entfernen gilt nur für das jeweilige Element. |
| Löschen gegen gleichzeitiges Bearbeiten | **Löschen gewinnt.** Die Bearbeitung bleibt im gelöschten Datensatz erhalten. Nur ein ausdrückliches Wiederherstellen hebt das Löschen auf. Zwischen Löschen und Wiederherstellen entscheidet das jüngere Ereignis. |
| Nummern (Patienten, Tagebuch) | Konfliktfrei durch den Gerätebuchstaben (A-12, B-12). |
| Uhr eines Geräts geht über 1 h vor | Das Ereignis wird übernommen, verstellt aber die eigene Uhr nicht (`clockWarnings`). |

Metadaten des zusammengeführten Stands: angelegt am/von aus dem Anlegen, geändert am/von aus dem jüngsten Ereignis, gelöscht am aus dem entscheidenden Löschen. Die lokale `version` zählt auf jedem Gerät selbst weiter. Sie dient nur dazu, dass offene Fenster einen neuen Stand erkennen.

Das Ergebnis hängt nicht von der Reihenfolge ab, in der Ereignisse eintreffen, und doppelt empfangene Ereignisse ändern nichts. Beides ist durch Tests abgesichert.

## Ablauf eines Abgleichs (`SyncEngine.sync`)

1. **Hochladen:** eigene Ereignisse nach `pushedThrough` in HLC-Reihenfolge, in Paketen zu 200. Nach jedem Paket wird `pushedThrough` gesichert.
2. **Abholen:** Seiten zu 500 ab `pullCursor`. Jede Seite wird in einem Speichervorgang übernommen (`RemoteChangeImporter`), danach wird der Cursor gesichert.
3. Bei Abbruch (offline, Fehler) geht der nächste Abgleich an derselben Stelle weiter. Es geht nichts verloren und nichts wird doppelt übernommen.

Der Stand je Einsatz liegt im Gerätedokument `syncCheckpoints`.

## Vertrag für das Backend (`SyncTransport`)

| Aufruf | Bedeutung |
|---|---|
| `push(events, mission)` | Ereignisse speichern. Bekannte IDs werden ignoriert (idempotent). Antwort erst, wenn dauerhaft gespeichert. |
| `pull(mission, after: cursor, limit)` | Ereignisse in **Ankunftsreihenfolge** nach `cursor`, einschließlich der eigenen. Antwort: Ereignisse, neuer Cursor, `hasMore`. |
| `purge(mission)` | Einsatz mit allen Ereignissen endgültig löschen (DSGVO). |

Vorschlag für HTTP, sobald ein Backend gebaut wird (noch nicht festgelegt):

```
POST /v1/missions/{missionID}/events          Body: [ChangeEvent]        → 204
GET  /v1/missions/{missionID}/events?after=N&limit=500                  → { events, cursor, hasMore }
DELETE /v1/missions/{missionID}                                         → 204
```

Das JSON-Format von `ChangeEvent` ist bereits festgelegt: Es ist dasselbe, das die App speichert, mit sortierten Schlüsseln und Datumswerten als Zahl. Rohwerte von `SyncEntityType` und `ChangeOperation` dürfen sich nicht ändern.

Fehler werden auf `SyncError` abgebildet: `notConnected`, `unauthorized`, `missionNotShared`, `offline`, `server(message)`.

## Verknüpfung lokal ↔ Backend

- Lokale Benutzer bleiben die Grundlage. Ein Benutzer kann optional mit einem Konto beim Backend verknüpft werden (`UserService.linkRemoteAccount`, Felder `remoteAccountID` und `remoteLinkedAt`). Das Lösen ist jederzeit möglich, lokale Daten bleiben dabei unverändert.
- Autor in Ereignissen ist immer die lokale `UserID`. Der Server ordnet sie über die Verknüpfung dem Konto zu.
- Vorschlag: Ein Einsatz wird erst übertragen, wenn er ausdrücklich freigegeben wird. Vorher bleibt er nur auf dem Gerät.

## Offen (Rückfrage Jonas)

1. Wo soll das Backend laufen (eigener Server in Deutschland, Anbieter)? Wer betreibt es (Kreisverband, Jonas)?
2. Anmeldung am Backend: eigenes Konto je Person oder ein Konto je Organisation mit lokalen Benutzern darunter?
3. Freigabe eines Einsatzes: automatisch für alle Geräte der Organisation oder je Einsatz per Code/QR?
4. Fotos und Sprachnotizen: mit übertragen (Datenmenge, Datenschutz) oder nur Text?
5. Alternativ oder zusätzlich: Abgleich ohne Server im lokalen Netz (iPads direkt untereinander, z. B. bei Großschadenslagen ohne Netz)?

## Mehrbenutzer: Varianten (Vorschlag, 2026-11-07)

Ausgangslage: Die App arbeitet lokal zuerst. Jede Änderung ist ein Ereignis, und das Zusammenführen ist fertig und getestet (Schritt 53). Für den Mehrbenutzerbetrieb fehlt nur noch der **Transport**. Jede der folgenden Varianten ist eine Umsetzung von `SyncTransport`. Der Rest der App bleibt gleich.

| | A: Vor Ort (fertig, Schritt 66) | B: Apple CloudKit | C: Eigener Server (Deutschland) | D: Fertiges Backend (Supabase EU o. Ä.) |
|---|---|---|---|---|
| Server nötig | nein | nein (Apple) | ja, selbst betrieben | ja, gemietet |
| Ohne Internet | ja (WLAN/Bluetooth, ~30–100 m) | nein | nein | nein |
| Fortlaufend aktuell | nur im Nahbereich | ja (Push) | ja (WebSocket/Push) | ja |
| Betrieb, Updates, Ausfälle | – | Apple | **wir** (auch nachts im Einsatz) | Anbieter |
| Kosten | 0 | im Entwicklerkonto enthalten (bei üblicher Nutzung) | ca. 10–30 €/Monat + Zeit | ab ca. 25 $/Monat |
| Datenschutz (Gesundheitsdaten, Art. 9 DSGVO) | Daten bleiben auf den Geräten | Apple als Auftragsverarbeiter; mit Ende-zu-Ende-Verschlüsselung sieht Apple nichts | volle Kontrolle, Hosting in Deutschland | AVV, EU-Region wählen |
| Voraussetzungen | – | iCloud/Apple-ID auf jedem Gerät | Server, Domain, Anmeldung | Konto beim Anbieter |
| Web-Ansicht (z. B. ILS), Android | nein | nein | ja, später möglich | ja |
| Aufwand für uns | erledigt | mittel | hoch | mittel (ohne Fremd-SDK über REST) |

**Empfehlung:**
1. **Sofort: A ausbauen.** Beitritt per QR-Code: Das Einsatzleiter-iPad zeigt einen Code, das andere Gerät scannt ihn. Solange beide in der Nähe sind, gleichen sie alle 30 s automatisch ab. Das funktioniert an jeder Einsatzstelle, auch ohne Netz.
2. **Dann: B (CloudKit) mit Ende-zu-Ende-Verschlüsselung je Einsatz.**
   - Der Einsatzschlüssel wird nur per QR-Code vor Ort weitergegeben. Apple speichert nur verschlüsselte Ereignisse und Dateien.
   - Kein eigener Server, kein Betrieb, keine Fremdbibliothek. Fortlaufend aktuell über Push.
   - Passt, wenn alle Geräte Apple-Geräte mit Apple-ID sind.
3. **Nur falls nötig: C.** Etwa wenn die ILS im Browser mitlesen soll, Android-Geräte dazukommen oder der Verband die Daten selbst hosten muss. Die Schnittstelle (`SyncTransport`, HTTP-Vorschlag oben) ist dafür schon festgelegt.

### Variante B im Detail: CloudKit (Stand 2026-11-08)

**Aufbau:**
- Jeder Einsatz bekommt eine eigene Zone in der privaten iCloud-Datenbank des Geräts, das ihn anlegt (Eigentümer = Apple-ID dieses Geräts).
- Die Zone wird über `CKShare` geteilt. Mitarbeitende sehen sie in ihrer *geteilten* Datenbank.
- Jedes `ChangeEvent` ist ein `CKRecord` (Name = Ereignis-ID, dadurch doppelt senden unschädlich). Dateien (Fotos, PDFs) sind `CKAsset`.
- `CloudKitTransport` setzt `SyncTransport` um: Senden = Datensätze speichern, Abholen = Zonenänderungen ab dem `CKServerChangeToken` (= unser Cursor). Zusammenführen bleibt `EntityHistory` – keine neue Konfliktlogik.
- Umgesetzt mit eigener Engine statt `CKSyncEngine` (E89): Unsere `SyncEngine` hat Ausgang, Cursor und Zusammenführen schon; CloudKit ist nur Transport (`CloudKitTransport` → `CloudZoneStore`).

**Aktualität:**
- Änderungen lösen einen stillen Push aus; Apple nennt „innerhalb von Sekunden“. Realistisch 1–5 s, bei schlechtem Netz länger.
- Stiller Push ist nicht garantiert (das System darf ihn verzögern oder zusammenfassen). Deshalb holt die App im Vordergrund zusätzlich alle 10–15 s selbst ab und sofort beim Öffnen.
- Ohne Netz wird lokal weitergearbeitet; die Warteschlange geht beim nächsten Netz raus. Vor Ort ohne Netz bleibt Variante A.

**Unterschiedliche Apple-IDs:**
- Ja – genau dafür ist `CKShare` gedacht. Jede Person braucht nur irgendeine Apple-ID mit iCloud auf dem Gerät.
- Beitritt: Teilen mit „Jeder mit dem Link kann bearbeiten“ (`publicPermission = .readWrite`); der Link wird auf dem Einsatzleiter-iPad als QR-Code angezeigt. Scannen → System öffnet ELRD → Annehmen. Apple-IDs der anderen muss man nicht kennen.
- Nach dem Einsatz (oder sofort nach dem Beitritt aller) kann der Link abgeschaltet werden; Beigetretene bleiben als feste Teilnehmer (Rechte vorher auf `readWrite` setzen, sonst verlieren sie den Zugriff).
- Rollen: Bearbeiten/Lesen pro Teilnehmer über CloudKit; „Einsatzleiter“ prüfen wir zusätzlich in der App.

**Einschränkungen:**
- Speicher zählt beim **Eigentümer** (iCloud-Speicher der Apple-ID des anlegenden Geräts) – Fotos beachten.
- Die Zone gehört dem Eigentümer: Löscht er sie oder beendet das Teilen, verlieren die anderen den Cloud-Zugriff (lokale Kopien bleiben). Eigentum ist nicht übertragbar; ein Wechsel der Einsatzleitung ist trotzdem möglich (Rolle in der App).
- Verwaltete Dienst-iPads: Wenn das MDM iCloud sperrt, geht CloudKit dort nicht. Mit verwalteten Apple-Accounts muss die IT iCloud für die App erlauben.
- Keine Web-Ansicht und kein Android.
- Testen nur auf echten Geräten mit zwei Apple-IDs (im CI-Simulator nicht möglich).

**Datenschutz:**
- Normale Felder verschlüsselt Apple mit eigenen Schlüsseln (Apple könnte technisch lesen).
- `encryptedValues` (Ende-zu-Ende, Schlüssel im iCloud-Schlüsselbund) funktioniert auch in geteilten Datenbanken; Dateien (`CKAsset`) werden ebenso über den Schlüsselbund geschützt. Unsere Ereignisse liegen daher komplett in einem verschlüsselten Feld; nur Ereignis-ID und Zeit bleiben lesbar.
- Folge: Der iCloud-Schlüsselbund muss auf den Geräten an sein. Setzt jemand den Schlüsselbund zurück, sind seine Cloud-Daten weg – die App lädt dann aus der lokalen Kopie neu hoch.
- Ein eigener Einsatzschlüssel per QR-Code ist damit nicht mehr nötig (einfacher als zuerst gedacht).

**Kosten:** für uns keine laufenden; Speicher tragen die Nutzer (iCloud). Aufwand: ca. 3 Schritte (Transport + Engine, Teilen/QR-Beitritt, Fehlerfälle/Gerätetest).

**In allen Varianten gleich:**
- Rollen je Einsatz: Einsatzleiter (alles), Mitarbeit (bearbeiten), Lesen.
- Beitritt per QR-Code.
- Ein Konflikt kann nie Daten löschen.
- Löschen gewinnt nur gegen gleichzeitiges Bearbeiten (E79).

**Fragen dazu:**
1. Haben alle Dienst-Geräte eine Apple-ID/iCloud? Werden sie über ein MDM verwaltet?
2. Soll die ILS oder Leitstelle mitlesen (Web), oder reicht der Bericht?
3. Wie viele Geräte arbeiten typischerweise gleichzeitig an einem Einsatz?
4. Wer ist datenschutzrechtlich verantwortlich (Kreisverband)? Gibt es Vorgaben zum Hosting?

## iCloud-Teilen: Umsetzung (2026-11-08)

**Module:** `ELRDCloud` mit
- `CloudZoneStore` (Schnittstelle) und `CloudKitZoneStore` (CloudKit). Der Container wird erst beim ersten Zugriff erzeugt – Simulator-Builds ohne iCloud-Berechtigung (CI) starten sonst nicht.
- `CloudKitTransport` (`SyncTransport` + `SyncFileTransport` auf die Zone).
- `CloudSyncCoordinator` (wann abgleichen, Wartezeiten, Teilen/Beitreten/Trennen, Kontowechsel).
- `CloudMissionDirectory` (Gerätedokument `cloudMissions`: Konto, Zone und Link je Einsatz).

**Ablage:** Zone `elrd-mission-<uuid>`; Datensatz `ELRDEvent` (Name = Ereignis-ID, verschlüsseltes Feld `payload` = JSON des `ChangeEvent`), `ELRDFile` (Name `file-<sha256>`, Feld `asset`). Zonenweiter `CKShare`, `publicPermission = .readWrite`.

**Wettläufe und wie sie gelöst sind:**

| Situation | Lösung |
|---|---|
| Push, Zeitgeber (15 s im Vordergrund), eigene Änderung, Vordergrund lösen gleichzeitig aus | `SyncEngine`: je Einsatz ein laufender Lauf, alle Aufrufe währenddessen teilen sich *einen* Folgelauf (der die neuen Änderungen sicher enthält). Koordinator: dasselbe Muster eine Ebene höher; eigene Änderungen 1,5 s gesammelt |
| Lauf überholt Lauf | Hochlade-Stand nur vorwärts (`advancePushed`) |
| Abbruch zwischen Übernehmen und Stand sichern | erst übernehmen, dann Stand; erneutes Abholen ist idempotent |
| Paket teilweise gespeichert | atomar je Paket; zu große Pakete werden geteilt; Stand rückt erst nach Erfolg vor |
| Erneutes Hochladen (Abbruch, zwei Geräte gleiche Datei) | fester Datensatzname, `.allKeys` = identisch überschreiben |
| Änderungsstand beim Dienst abgelaufen | einmal von vorn abholen, nichts doppelt |
| Zweimal „Teilen“ getippt / zwei iPads desselben Kontos teilen gleichzeitig | eine Aufgabe je Einsatz; Zonenname fest aus Einsatz-ID; Freigabe mit `.ifServerRecordUnchanged`, bei Konflikt gilt die vorhandene |
| Link zweimal geöffnet | eine Aufgabe je Link; Verknüpfen idempotent |
| Verlassen / Teilen beenden / Kontowechsel während eines Laufs | Einsatz sperren, auf Ende aller Läufe warten (`waitUntilIdle`), erst dann Stand und Verbindung verwerfen |
| Fremde Ereignisse kamen per Datei oder iPad in der Nähe | Zähler `foreignAccounted`: mehr fremde Ereignisse als über den Server gekommen → einmal weiterleiten |
| Dienst ausgelastet / kein Netz | Wartezeit (Vorgabe des Dienstes, sonst 5 → 300 s), höchstens ein geplanter Neuversuch, Auslöser in der Wartezeit fragen nicht an |
| Übernommene Änderungen während ein Fenster offen ist | offene Einsätze werden neu geladen; eine Aktion auf altem Stand wird wie bisher erkannt (`staleWrite`) und wiederholt |
| Schlüsselbund beim Teilenden zurückgesetzt | Zone löschen, neu anlegen, alles aus der lokalen Kopie hochladen; andere müssen neu beitreten |

**Einrichtung (einmalig, Jonas, in Xcode/Apple-Developer):**
1. Xcode → Ziel ELRD → *Signing & Capabilities*: **iCloud** hinzufügen, *CloudKit* anhaken, Container **`iCloud.ELRD.App`** anlegen/auswählen. **Push Notifications** hinzufügen. **Background Modes** → *Remote notifications* (steht schon in der Info.plist). Die Datei `ELRD.entitlements` ist bereits eingetragen.
2. Ändert sich die Bundle-ID (offene Frage `ELRD.App` vs. `ELRD.RescueCommander`), Container-ID in `ELRD.entitlements` und `CloudKitZoneStore.containerIdentifier` mitziehen.
3. Erster Test auf zwei Geräten (Entwicklungsumgebung): legt die Datensatztypen `ELRDEvent`/`ELRDFile` automatisch an.
4. **Vor TestFlight:** CloudKit Console → Schema *Deploy to Production*. Sonst funktioniert es in TestFlight nicht.
5. Gerätetest: siehe `GERAETETEST.md`, Abschnitt iCloud.


## Beitritt mit Genehmigung (Schritt 116, 2026-11-10)
Einstellung „Beitritt genehmigen“ (Einstellungen › Allgemein, je Gerät der Einsatzleitung). Neue Freigaben entstehen dann mit `publicPermission = .none`: Der Link allein öffnet nichts, vor der Zulassung kommt kein Datensatz des Einsatzes auf ein fremdes Gerät.

Ablauf:
1. Gast: „Einsatz beitreten“ → Link/QR → Zugriff verweigert → „Beitritt anfragen“ mit Namen. Die Anfrage liegt in der **öffentlichen Datenbank** des Containers (`ELRDJoinRequest`): `shareKey` = SHA-256 des Links, `sealed` = Name, iCloud-Benutzerkennung und Zeit, AES-GCM-verschlüsselt mit einem Schlüssel aus dem Link. Ohne den Link ist nichts lesbar oder einem Einsatz zuzuordnen.
2. Einsatzleitung: Der Arbeitsbereich sieht alle 15 s nach (nur bei eigenen Freigaben mit Genehmigung) und zeigt oben „… möchte beitreten – Zulassen/Ablehnen“. Zulassen nimmt die Person über `shareParticipant(forUserRecordID:)` als Teilnehmer (lesen/schreiben) in den `CKShare` auf.
3. Die Entscheidung liegt als `ELRDJoinDecision` (Name aus der Anfrage abgeleitet) in der öffentlichen Datenbank. Das Gerät des Gasts sieht nach (offenes Beitrittsblatt alle 5 s, Einsatzliste alle 30 s), tritt bei Zulassung bei, öffnet den Einsatz und löscht seine Anfrage.

**Einrichtung im CloudKit-Dashboard (Jonas, einmalig):**
- Satztyp `ELRDJoinRequest`: Felder `shareKey` (String, **Index: Queryable**), `sealed` (Bytes).
- Satztyp `ELRDJoinDecision`: Feld `decision` (String).
- Sicherheitsrollen der öffentlichen Datenbank: Standard („World: lesen“, „Creator: schreiben“) genügt.
- Schema danach in die Produktionsumgebung übernehmen („Deploy Schema Changes“).

Grenzen: Bereits geteilte Einsätze behalten ihre Art (zum Umstellen Teilen beenden und neu teilen). Der QR-Code mit der Systemkamera funktioniert bei Genehmigungspflicht nicht – gescannt wird in ELRD unter „Einsatz beitreten“.
