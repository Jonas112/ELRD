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
