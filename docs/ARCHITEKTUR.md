# Architektur ELRD

## Rahmen

- **Plattform:** iPad only, Mindestversion iPadOS 17.0. Funktionen ab iPadOS 18 nur hinter `if #available(iOS 18, *)`.
- **UI:** SwiftUI, `@Observable`, Swift Concurrency (`async/await`, `@MainActor` für UI-Zustand).
- **Sprache:** Swift 5.10-Modus mit strikter Concurrency-Prüfung „complete“ (Umstieg auf Swift 6 später ohne Umbau).
- **Externe Abhängigkeiten:** keine. MapKit, PDFKit, AVFoundation, CryptoKit, StoreKit 2 und SwiftData sind Systemframeworks.

## Module

Die App ist dünn; die Logik liegt in einem lokalen Swift Package `ELRDKit` mit klar getrennten Modulen.

```
ELRD (App-Target)            – App-Einstieg, Dependency-Wiring, Assets
└─ ELRDKit (lokales Package)
   ├─ ELRDDomain             – reine Werttypen, Enums, Regeln. Kein UI, kein SwiftData.
   ├─ ELRDPersistence        – SwiftData-Modelle, Mapping Domain ⇄ Persistenz, Repositories
   ├─ ELRDSync               – Änderungsjournal, Sync-Protokoll (zunächst nur lokal)
   ├─ ELRDAuth               – Benutzer, Passwort-Hashing, Keychain, AuthProvider
   ├─ ELRDEntitlements       – Freischaltungen/Abo-Status (StoreKit 2 später)
   ├─ ELRDReports            – PDF-Engine und Berichtsvorlagen
   ├─ ELRDStammdaten         – Stammdatenmodell und CSV-Regionsimport
   └─ ELRDFeatures           – SwiftUI-Screens je Funktionsbereich, Designsystem
```

Abhängigkeitsrichtung: `Features → (Reports, Auth, Entitlements, Persistence, Sync) → Domain`. Domain kennt niemanden.

## Datenfluss

```
View ──Aktion──▶ MissionStore (@Observable, @MainActor)
                    │  führt Command aus (z. B. AddPatient, AssignUnit)
                    ▼
               CommandHandler ──▶ Repository (SwiftData) ── speichert Entität
                    │
                    └──▶ ChangeJournal ── speichert ChangeEvent (Wer, Wann, Was)
                                      └─▶ Protokollansicht + spätere Synchronisation
```

Domänentypen heißen `Mission`, `MissionSection`, `MissionUnit` (nicht `Section`/`Unit`, siehe E16). Kennungen sind typsicher (`EntityID<Tag>`), Zeitpunkte werden Fachmethoden immer als Parameter übergeben.

Regel: **Views schreiben nie direkt in die Persistenz.** Jede Änderung ist ein Command. Dadurch entstehen Protokoll und Sync-Daten automatisch und vollständig.

## Mehrbenutzerfähigkeit (vorbereitet, noch nicht aktiv)

Ziel: Mehrere Nutzer bearbeiten denselben Einsatz auf mehreren Geräten.

1. **IDs:** Jede Entität hat eine `UUID` als Primärschlüssel. Keine fortlaufenden Integer-IDs als Schlüssel.
2. **Partition:** Alle einsatzbezogenen Entitäten tragen `missionID`. Ein Einsatz ist die Einheit für Freigabe und Sync.
3. **Metadaten je Entität:** `createdAt`, `createdBy`, `updatedAt`, `updatedBy`, `version` (Int, steigt bei jeder Änderung), `deletedAt` (Soft-Delete, nie physisch löschen solange synchronisiert wird).
4. **Änderungsjournal:** Append-only `ChangeEvent` mit `id`, `missionID`, `entityType`, `entityID`, Operation (insert/update/delete), geänderten Feldern mit neuem Wert, `authorID`, `deviceID`, Hybrid-Logical-Clock-Zeitstempel.
5. **Konfliktstrategie (Entwurf):** Feldweise „letzter Schreiber gewinnt“ nach HLC-Zeitstempel. Listen (Patienten, Einheiten, Tagebuch) werden über Insert/Delete-Ereignisse zusammengeführt, nicht als Ganzes überschrieben.
6. **Patientennummern:** Anzeige-Nummer ist nicht der Schlüssel. Vergabe so, dass zwei Geräte offline keine gleiche Nummer erzeugen (Variante wird in Schritt 7 festgelegt, z. B. Gerätekürzel + laufende Nummer, oder Nummernblöcke je Gerät).
7. **Transport:** Protokoll `SyncTransport` mit zwei späteren Implementierungen denkbar: ELRD-Backend (bevorzugt, DSGVO, Mandantentrennung) oder lokales Netzwerk. Zunächst nur `NoopTransport`.

## Benutzer & Anmeldung

- Lokale Benutzer mit Passwort bleiben möglich.
- Passwort wird nie im Klartext gespeichert: PBKDF2-SHA256 mit Salt und hoher Iterationszahl, Hash in SwiftData, Sitzungsgeheimnis in der Keychain.
- `AuthProvider`-Protokoll mit `LocalAuthProvider`; ein `RemoteAuthProvider` (ELRD-Backend) kann später ergänzt werden.
- Konto-Verknüpfung: Ein lokaler Benutzer kann optional eine `remoteAccountID` erhalten. Lokal und Backend bleiben dadurch kombinierbar, das Backend ist nie Pflicht.

## Abo / Freischaltungen

- `EntitlementService` liefert, welche Funktionen verfügbar sind (`isEnabled(.pdfExport)` usw.).
- Bis zur Abo-Integration (Schritt 51) liefert eine Entwicklungs-Implementierung „alles frei“.
- Features fragen nur den Service, nie StoreKit direkt.

## Berichte (PDF)

Ziel: modernes, ruhiges Layout und **vom Benutzer frei steuerbarer Inhalt**.

- **Eigene Engine** auf Basis von `UIGraphicsPDFRenderer` und Core Text: echter, durchsuchbarer Text, automatische Seitenumbrüche, Tabellenköpfe werden auf Folgeseiten wiederholt, Kopf- und Fußzeile mit „Seite x von y“.
- **Berichtsvorlage** = geordnete Liste von Kapiteln. Jedes Kapitel ist an-/abschaltbar und hat eigene Optionen, z. B.:
  - Patienten: Spaltenauswahl, Filter nach SK/Abschnitt/Status, Tabelle oder Einzelbogen je Patient
  - Tagebuch: Zeitraum, Typen (Text/Foto/Audio-Hinweis), Bildgröße
  - Organisation: mit/ohne Platzhalter, mit Patientenzuordnung
- **Gestaltung (Theme):** Logo/Banner, Akzentfarbe, Schriftgrößen, SK-Farbmarker, Hoch-/Querformat.
- **Standardvorlagen:** Gesamtbericht, Kurzbericht, Klinikbericht (ein Patient + ausgewählte Tagebucheinträge). Eigene Vorlagen speicher- und teilbar.
- **Vorschau** mit PDFKit, Rendering im Hintergrund (nicht auf dem Main Thread).

## iPad-Layout (alle Größen)

- Navigation: `NavigationSplitView` mit Seitenleiste für die Bereiche Übersicht, Patienten, Organisation, Karte, Tagebuch, Nachrichten.
- Layouts reagieren auf `horizontalSizeClass` und verfügbare Breite (`ViewThatFits`, `GeometryReader` nur wo nötig): Split View 1/3, Slide Over, Stage Manager, iPad mini bis iPad Pro 13″.
- Hardware-Tastatur: Kurzbefehle für häufige Aktionen (neuer Patient, Suche, Bereichswechsel).
- Dark Mode und Dynamic Type von Anfang an.

## Persistenz

- SwiftData als lokaler Speicher, gekapselt hinter Repository-Protokollen. Domain-Typen sind unabhängig von SwiftData.
- Damit bleibt ein späterer Wechsel (z. B. zu SQLite/GRDB, falls SwiftData unter iPadOS 17 Probleme macht) auf `ELRDPersistence` begrenzt.
- Binärdaten (Fotos, Audio, Zeichnungen) als Dateien im App-Container, in der Datenbank nur Referenz + Prüfsumme.
- Datenschutz: Dateischutz `completeUntilFirstUserAuthentication` für Datenbank und Anhänge.
