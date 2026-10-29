# Fortschritt

**Nächster Schritt:** 15 – Anmeldung / Benutzerwahl
**Weitermachen:** In einer neuen Sitzung „weiter mit Schritt N“ schreiben. Claude liest zuerst diese Datei, `ARCHITEKTUR.md` und `ENTSCHEIDUNGEN.md`.

Ablauf je Schritt: Claude schreibt Code, committet und prüft den CI-Build (GitHub Actions) selbst → Fehler behebt Claude im selben Schritt. Jonas testet zusätzlich auf dem Gerät.
Status: ⬜ offen · 🔨 in Arbeit · 🧪 wartet auf Build in Xcode · ✅ fertig

## A – Fundament
| # | Schritt | Status |
|---|---|---|
| 1 | Analyse, Funktionsinventar, Architektur, Entscheidungen | ✅ |
| 2 | Projektgerüst: Xcode-Projekt (iPad, iPadOS 17), lokales Package `ELRDKit` mit Modulen, CI-Build | ✅ |
| 3 | Domäne 1: Werttypen & Enums (SK, Einheitentyp, Alarmstichwort, Einsatzart, Geschlecht, Schockraum, Klinikstatus, IVENA) | ✅ |
| 4 | Domäne 2: Einsatz, Abschnitt, Einheit | ✅ |
| 5 | Domäne 3: Patient, Verletzung, Klinik | ✅ |
| 6 | Domäne 4: Tagebuch, Anhang, Nachricht, Protokoll, Kartenobjekte | ✅ |
| 7 | Sync-Metadaten, Änderungsjournal, HLC-Zeitstempel, Patientennummern-Vergabe | ✅ |
| 8 | SwiftData-Schema und Mapping | ✅ |
| 9 | Repositories (SwiftData + In-Memory) | ✅ |
| 10 | Command-Schicht und `MissionStore`, Protokoll aus Journal, Testdaten | ✅ |
| 11 | Stammdatenmodell und CSV-Regionsimport | ✅ |
| 12 | Benutzer & Anmeldung: Passwort-Hash, Keychain, `AuthProvider`, Konto-Verknüpfung vorbereitet | ✅ |
| 13 | Freischaltungs-Schicht (Entitlements) für späteres Abo | ✅ |
| 14 | App-Rahmen: adaptive Navigation, Designsystem, Tastaturkürzel-Grundlage | ✅ |

## B – Einsätze
| # | Schritt | Status |
|---|---|---|
| 15 | Anmeldung / Benutzerwahl | ⬜ |
| 16 | Einsatzliste, Filter, neuer Einsatz | ⬜ |
| 17 | Einsatzdaten bearbeiten, Einsatz beenden | ⬜ |

## C – Patienten
| # | Schritt | Status |
|---|---|---|
| 18 | Patientenliste, SK-Schnellanlage, Sortierung, Zähler | ⬜ |
| 19 | Detail: Personendaten, SK, Nummern mit Dublettenprüfung | ⬜ |
| 20 | Detail: Verletzungen | ⬜ |
| 21 | Detail: IVENA, Schockraum, intubiert/stabil | ⬜ |
| 22 | Detail: Transport, Zielklinik, Anmeldestatus | ⬜ |
| 23 | Patienten-Grafikansicht | ⬜ |

## D – Organisation
| # | Schritt | Status |
|---|---|---|
| 24 | Abschnitte | ⬜ |
| 25 | Einheiten: Stammdaten, temporär, Filter, Suche | ⬜ |
| 26 | Platzhalter, Alarmstichworte RD 1–5, Platzhalter ersetzen | ⬜ |
| 27 | Drag & Drop | ⬜ |

## E – Lagekarte
| # | Schritt | Status |
|---|---|---|
| 28 | Kartenbasis: Standort, OSM/OpenTopo, Maßstab | ⬜ |
| 29 | Abschnitte auf der Karte | ⬜ |
| 30 | Kreis- und Rechteck-Overlays, Overlay-Liste | ⬜ |
| 31 | Freihandzeichnen | ⬜ |
| 32 | Kartenausschnitt ins Tagebuch, Drucken (what3words optional) | ⬜ |

## F – Tagebuch & Nachrichten
| # | Schritt | Status |
|---|---|---|
| 33 | Texteinträge und Vorlagen | ⬜ |
| 34 | Fotoeinträge | ⬜ |
| 35 | Audioeinträge | ⬜ |
| 36 | Nachrichten und Protokollansicht | ⬜ |

## G – Übersicht
| # | Schritt | Status |
|---|---|---|
| 37 | Einsatz-Dashboard | ⬜ |

## H – Berichte (PDF)
| # | Schritt | Status |
|---|---|---|
| 38 | PDF-Engine: Seitenfluss, Umbrüche, Kopf-/Fußzeile, Seitenzahlen | ⬜ |
| 39 | Berichts-Design: Theme, Typografie, Tabellen, Logo/Banner | ⬜ |
| 40 | Berichtsmodell: Vorlage, Kapitel, Optionen, Filter | ⬜ |
| 41 | Kapitel Einsatzinfo und Organisation | ⬜ |
| 42 | Kapitel Patienten (Tabelle und Einzelbogen) | ⬜ |
| 43 | Kapitel Tagebuch und Protokoll | ⬜ |
| 44 | Berichts-Editor mit Live-Vorschau | ⬜ |
| 45 | Vorlagen verwalten, Standardvorlagen (Gesamt, Kurz, Klinik) | ⬜ |
| 46 | Ausgabe: Teilen, Drucken, Mail an ILS, Dateinamen | ⬜ |

## I – Einstellungen
| # | Schritt | Status |
|---|---|---|
| 47 | Allgemeine Einstellungen, Fahrzeugbilder, Banner | ⬜ |
| 48 | Stammdatenverwaltung und Regionsimport-Oberfläche | ⬜ |
| 49 | IVENA-Einstellungen | ⬜ |
| 50 | Onboarding und Vereinbarungen | ⬜ |

## J – Abschluss
| # | Schritt | Status |
|---|---|---|
| 51 | Abo mit StoreKit 2 | ⬜ |
| 52 | Robustheit: Autosave, Fehlerbehandlung, Barrierefreiheit, Tastatur | ⬜ |
| 53 | Sync-Schnittstelle und Konfliktstrategie finalisieren, Verknüpfung lokal ↔ Backend | ⬜ |

## Übergabenotizen
- **Schritt 1 (2026-10-17):** Altes Repo analysiert, Inventar in `FUNKTIONEN.md`, Zielbild in `ARCHITEKTUR.md`, Beschlüsse in `ENTSCHEIDUNGEN.md`. Noch kein Code. Für Schritt 2 offen: Xcode-Version auf Jonas' Mac (für das Projektformat).
- **Schritt 2 (2026-10-17):** Jonas nutzt Xcode 26.6. Projekt `ELRD.xcodeproj` (objectVersion 77) mit synchronisiertem Ordner `ELRD/` – neue Dateien dort erscheinen automatisch, `project.pbxproj` muss nicht angefasst werden. Lokales Package `ELRDKit` (ein Produkt `ELRDKit`, 8 Module als Platzhalter, Test-Target `ELRDDomainTests` mit Swift Testing). Neue Module = neues Target in `ELRDKit/Package.swift` + Eintrag im Produkt. Bundle-ID vorläufig `ELRD.App`, Team in Xcode unter „Signing & Capabilities“ setzen. CI: `.github/workflows/build.yml` auf `macos-26`, läuft nur bei Code-Änderungen; Build-Logs als Artefakt. CI grün (Build + Tests auf iPad-Simulator, Xcode 26.6). Claude prüft Builds selbst per `gh run list/view -R Jonas112/ELRD` (Fehler stehen als Annotationen; Log-Download ist über den Proxy gesperrt). Jonas: lokal einmal öffnen und Team unter „Signing & Capabilities“ setzen.
- **Schritt 3 (2026-10-18):** Grundtypen in `ELRDDomain`: `Sichtungskategorie`, `UnitType`, `Alarmstichwort` (inkl. `unitsToCreate`), `MissionType` (optional statt „Einsatzart auswählen“), `Gender`, `TraumaRoom`, `HospitalRegistrationState`, `BodyRegion`/`BodySide`, `TreatmentPriority`, `RMI`, `PatientAllocationCode` (PZC), `RGBColor` (Farben ohne UI-Framework, mit Kontrastberechnung), Protokoll `DisplayNamed`. Rohwerte 1:1 wie ELRDRG/Backend (E14), Tests sichern das ab. 17 Tests grün. IVENA-Katalogdaten (Bayern 187 RMIs, Untermain aus txt) noch nicht übernommen → Schritt 11/49. Offen für Schritt 22: welche Einheitentypen Patienten transportieren dürfen (in `SelectUnitVC` nachsehen).
- **Schritt 4 (2026-10-18):** `EntityID<Tag>` (typsicher, JSON = UUID-String) mit Aliassen `MissionID`, `SectionID`, `UnitID`, `PatientID`, `UserID`, `DeviceID`, `MasterUnitID`, `MasterSectionID`. `EntityMetadata` (createdAt/By, updatedAt/By, version, deletedAt) + Protokolle `VersionedEntity`, `MissionScoped`, `.active`-Filter. `GeoCoordinate`. `Mission` (Jahresnummer je Kalenderjahr, ILS-Nummer als Text, Beenden/Wiederöffnen wie ELRDRG, `validate()`), `MissionSection` (genau ein Initialabschnitt via `applyingInitialRule`), `MissionUnit` (reale Einheit / Platzhalter mit fortlaufender Nummer, `placeholders(for: Alarmstichwort)`, `replacePlaceholder` behält ID und Abschnitt). Typnamen mit Präfix `Mission…` wegen Konflikt mit `SwiftUI.Section` und `Foundation.Unit` (E16). Zuordnung Patient ↔ Einheit kommt in Schritt 5 an den Patienten. Zeitpunkte werden immer als Parameter übergeben (testbar). 35 Tests grün. Hinweis: `#expect` verträgt keine mutierenden Aufrufe – vorher in `let` speichern.
- **Schritt 5 (2026-10-18):** `Patient` (Nummer = Anzeige, nicht Schlüssel; Dubletten werden angezeigt statt verhindert; `estimatedAge` + `birthDate`, Geburtsdatum hat Vorrang, `setAge` verschiebt Geburtsdatum wie ELRDRG; `isChild` explizit; Verletzungen eingebettet mit eigener `InjuryID`; `traumaRoom`, `isIntubated`, `isCirculationUnstable`; `rmiCode` + `treatmentPriority` → `allocationCode`). Einheiten-Zuordnung über `Patient.unitIDs` (mehrere je Patient, wie ELRDRG). `PatientOutcome`: `.transported(startedAt:)` oder `.released(at:handledBy:)` – Entlassen löst Einheiten, merkt deren Namen, Transportziel optional entfernen (ELRDRG fragt nach). `PatientStatus` (wartet/zugeordnet/Transport/entlassen). `HospitalSnapshot` (Kopie aus Stammdaten), Klinikwechsel setzt Anmeldestatus zurück. Neue IDs: `InjuryID`, `MasterInjuryID`, `MasterHospitalID`. Altes Feld `Victim.schockraum` (Bool) entfällt, nur noch `traumaRoom`. 50 Tests grün.
- **Schritt 6 (2026-10-18):** Vorab auf Wunsch: Kreislauf jetzt `CirculationState` (unbekannt/stabil/instabil, Rohwerte 0/1/2) statt Bool; alter Wert `stabil=true` → `.stabil`, `false` → `.unbekannt`. Neu: `JournalEntry` (laufende Nummer – gelöschte zählen mit –, `occurredAt` getrennt von Erfassungszeit, `JournalOrigin` manuell/automatisch/Lagekarte, Anhänge, `isMissionThumbnail`), `FileAttachment` (Datei-Verweis: Art, Größe, SHA-256, Dauer, Pixelmaße; Dateiname nur aus UUID + Endung), `MissionMessage` (Absender, Art, einmalige Quittierung mit Benutzer), `MissionLogEntry` (Kategorie, Ebene user/admin/developer wie ELRDRG, `LogSubject` für Sprung zum Datensatz; Patienten im Text nur per Nummer), `MapObject` + `MapShape` (Kreis 1–50 000 m, Rechteck, Zeichnung als `FileAttachment` über `GeoBounds`), `GeoBounds` statt `MKMapRect`. Namenskonflikt: Swift Testing hat `Attachment` → unser Typ heißt `FileAttachment` (E22). 66 Tests grün. Domänenmodell damit vollständig.
- **Schritt 7 (2026-10-18):** Jonas: Nummern mit Buchstaben-Präfix. `SerialNumber` (Präfix 1–2 Buchstaben A–Z oder leer für Altdaten, Wert ≥ 1, Anzeige/JSON „A-12“, Parser „a12“/„A-12“/„12“, Integer-Literal = ohne Präfix) für `Patient.number` und `JournalEntry.number`; `nextNumber(prefix:existing:)` zählt jetzt auch gelöschte Patienten. `DeviceIdentity` (DeviceID + Präfix, Standard „A“; Speicherort folgt mit Einstellungen). `ELRDSync`: `HybridTimestamp`/`HybridLogicalClock` (Drift-Grenze 1 h), `JSONValue`/`JSONValueCoder`, `ChangeEvent` (Einsatz, Entitätsart, ID, Operation insert/update/delete/restore, Feldänderungen, HLC, Autor), `FieldChange` (`set`, `upsertElement`, `removeElement`), `SyncEntity`-Konformanz aller Einsatz-Entitäten, `ChangeRecorder.event(old:new:…)` (Metadaten ausgenommen, Listen mit `id`/UUID-Texten elementweise), `MergeState` (LWW je Feld/Element, Listen nie als Ganzes überschrieben, Reihenfolge nach erstem Einfügen; Tests: Permutationen, Idempotenz, Round-Trip Patient). Löschen/Wiederherstellen der Metadaten beim Zusammenführen folgt mit Schritt 53. Test-Makros: keine `inout`-Argumente in `#expect`/`#require`. CI zeigt jetzt alle Testläufe: 74 Domäne + 15 Sync.
- **Schritt 8 (2026-10-21):** Speicherkonzept E28: zwei flache SwiftData-Tabellen ohne Beziehungen. `EntityRecord` (`entityID` unique, `entityType` = `SyncEntityType`-Rohwert, `missionID`, `isSoftDeleted`, `entityVersion`, `updatedAt`, `payloadVersion`, `payload` = JSON der Domänenentität) und `ChangeRecord` (Journal: `eventID` unique, `missionID`, Entität, HLC zerlegt in `wallTime`/`counter`/`deviceID` zum Sortieren, `isPendingUpload`, `payload`). Achtung: `PersistentModel` belegt `id`/`isDeleted` – daher andere Spaltennamen. `ELRDSchemaV1` + `ELRDMigrationPlan` (noch ohne Stufen); typealiases `EntityRecord`/`ChangeRecord`. `RecordMapping` (JSON mit sortierten Schlüsseln wie Sync; prüft Typ und `payloadVersion`). `PersistenceStore.makeContainer(storeURL:)` → `Application Support/ELRD/ELRD.store`, Dateischutz `completeUntilFirstUserAuthentication`; `makeInMemoryContainer()` für Tests/Previews. Regel: neue Felder in Domänentypen optional oder mit Default beim Dekodieren. `ELRDPersistence` hängt jetzt von `ELRDSync` ab; neues Test-Target `ELRDPersistenceTests` (9 Tests). CI-Hinweise: Sendable-Warnungen bei SwiftData-KeyPaths sind SDK-bedingt und harmlos; GitHub stellte einmal 15 min keinen macOS-Runner bereit → `gh run rerun <id>`. In `#expect` keine `allSatisfy`/inout-Aufrufe.
- **Schritt 9 (2026-10-22):** `EntityRepository` (`@MainActor`-Protokoll): `apply(ChangeSet)` atomar (Entitäten + Journal, ganz oder gar nicht), `entity(_:id:)`, `entities(_:in:includeDeleted:)`, `missions()` (neueste zuerst), `changeEvents(in:)` (HLC-Reihenfolge), `latestTimestamp(of:)` (HLC nach Neustart fortsetzen), `purgeMission` (DSGVO, Dateien separat). `ChangeSet.upsert` erzeugt `EntitySnapshot` (gemeinsame JSON-Form, letzte Vormerkung je Entität gewinnt), `record(event)` ohne Doppelte. Schutz gegen veraltete Stände (`staleWrite`): nur höhere Version oder identischer Inhalt darf ersetzen – wichtig bei mehreren iPad-Fenstern. `SwiftDataRepository` (eigener `ModelContext`, Autosave aus, `rollback()` bei Fehler), `InMemoryRepository` (Vorschauen/Tests, `failNextApply`). Vertragstests laufen gegen beide (`RepositoryKind`). 19 Persistenz-Tests. CI-Fehlerfilter reagiert nicht mehr auf „failed“ in Testnamen.
- **Schritt 10 (2026-10-22):** Neues Modul `ELRDStore` (Domain, Sync, Persistence; ohne SwiftUI) – E32. `MissionCommand` (`@MainActor`, `Output`, `allowedOnClosedMission`) arbeitet nur auf `MissionDraft`: `insert`/`update(_:id:)`/`updateMission`/`delete` (Metadaten setzt der Entwurf; `update` ohne echte Änderung erzeugt nichts), `log(...)` (Protokoll als `MissionLogEntry`-Entitäten, nicht aus dem Journal abgeleitet – E33), `addJournalEntry` (Nummer mit Gerätepräfix). `MissionStore` (`@Observable`, `state: MissionState` inkl. gelöschter Einträge; Anzeigehilfen `activePatients` usw.): `create(NewMissionRequest)` (Jahresnummer, Abschnitte, Initialabschnitt, Einsatzleiter = Benutzer), `perform` (Entwurf → `ChangeSet` mit Journal → atomar speichern → Stand übernehmen; bei `staleWrite` neu laden und einmal wiederholen; beendeter Einsatz schreibgeschützt), `reload`, `changeEvents`. `DeviceClock` je App, startet beim letzten eigenen Zeitstempel. Einheitliche Sortierung `StableOrder` (Anlagezeit, dann UUID) für geänderten und geladenen Stand. Commands bisher: `EditMission` (mit Prüfregeln), `CloseMission`/`ReopenMission` (automatischer Tagebucheintrag wie ELRDRG), `AddPatient`, `SetTriage`, `AddAlarmstichwort` (Initialabschnitt), `AddJournalText`. Weitere Commands entstehen mit den jeweiligen Oberflächen-Schritten. `PreviewData.makeStore()` (VU-Beispiel ohne Personennamen). 11 Store-Tests (beide Repository-Arten, Fensterkonflikt, Neustart, Fehlerfälle). Hinweis: In `inout`-Kontexten den Entwurf nicht gleichzeitig lesen und ändern (Werte vorher in `let`).
- **Schritt 11 (2026-10-29):** Domäne `MasterData/`: `MasterUnit` (Funkrufname, `UnitType` + Originalbezeichnung `typeLabel` z. B. „HVO“, Besatzung, Herkunft), `MasterHospital` (inkl. Anmelde-E-Mail, `snapshot`), `MasterInjury`, `MasterSection` (`addAutomatically`, `isInitial`), `TextTemplate`; `MasterDataSet` als ein Dokument mit `revision` (E35), `merge` (`addMissing` / `replaceRegion`, Doppelte über Funkrufname bzw. Name+Ort, Groß/klein und Leerraum egal), `unusedUnits`, `automaticSections`. `RMI` + `triageHint`, `RMICatalog` (Kategorien, Suche). `ELRDStammdaten`: `CSVParser` (; oder „,“, Anführungszeichen, BOM, CRLF, Latin-1-Fallback), `MasterDataImporter` (Spalten über Überschrift, ohne Überschrift Standardreihenfolge; Teilerfolg mit `ImportIssue`), `UnitTypeMapping` (alle Bezeichnungen der Listen), `IVENACatalogParser` (Tab-Format und ELRDRG-Textformat), `BundledMasterData` (7 Regionspakete, Diagnosen, IVENA Bayern/Untermain, `initialMasterData()`). Ressourcen in `Sources/ELRDStammdaten/Daten` – **nicht „Resources“ nennen**, sonst scheitert die Code-Signatur des Bundles. Persistenz: `DocumentRecord` (Schema V1 erweitert, E36) + `DocumentRepository` (`DocumentKey.masterData`). **Datenkorrekturen gegenüber ELRDRG:** Spaltenzuordnung Aschaffenburg, erstes Fahrzeug Coburg, 35 Klinikzeilen mit vertauschter Straße/Ort, Längengrad KHS Hammelburg (989813) und Klinikum Kaufbeuren (1.061.145), verschmolzene Diagnose „Unterschenkel#“, „Commotio“; Rhön-Grabfeld-Liste steht dreifach in der Datei → 48 Fahrzeuge nach Dublettenprüfung. Nebenbei: Protokoll streng chronologisch (gleiche Millisekunde → +1 ms), CI gibt bei Abstürzen das Protokollende aus. Tests: 21 Stammdaten, 20 Persistenz, 12 Store.
- **Schritt 12 (2026-10-29):** `ELRDAuth` (hängt von Domain + Persistence ab). `PasswordHasher`: PBKDF2-HMAC-SHA256 über CommonCrypto, 600 000 Durchläufe (OWASP 2023), 16 Byte Salt, 32 Byte Schlüssel, Vergleich in konstanter Zeit, Unicode-NFC-Normalisierung, `needsRehash` → beim Login automatisch auf aktuelle Durchläufe angehoben; RFC-7914-Testvektor. `PasswordPolicy.minimumLength = 6` (ohne Zeichenklassen-Pflicht, E39). `UserAccount` (Vor-/Nachname, Funkrufname, E-Mail, Telefon, Rolle `admin`/`commander`, optionaler Hash, `remoteAccountID`, Deaktivierung statt Löschen, Fehlversuche/Sperre) in `UserDirectory`, gespeichert als Dokument `DocumentKey.users`. `UserService` (`@Observable`, MainActor): `createInitialAdmin` (Onboarding), `createUser`/`setRole`/`deactivate` (nur Admin), `updateProfile` (selbst oder Admin), `changePassword`/`resetPassword`, `login` (Sperre ab 5. Fehlversuch: 30 s, dann verdoppelt bis 15 min), `logout`, `restoreSession` (Benutzer-ID in `SecureStore`), `linkRemoteAccount`. Regeln: Admins immer mit Passwort, Einsatzleiter optional ohne; letzter aktiver Admin nicht herabstufbar/deaktivierbar. `KeychainStore` (`AfterFirstUnlockThisDeviceOnly`) + `InMemorySecureStore` (Keychain wird in CI nicht getestet – Testbundles ohne Host-App haben keinen Keychain-Zugriff). `AuthProvider`-Protokoll, `LocalAuthProvider` hasht im Hintergrund (`Task.detached`). 18 Auth-Tests.
- **Schritt 13 (2026-10-29):** `ELRDEntitlements` (ohne Abhängigkeiten): `Feature` (`missionEditing`, `missionViewing`, `reportExport`, `customReportTemplates`, `multiDevice`, `backendSync`), `EntitlementState` (`development`, `trial`, `subscribed`, `expired`) mit `summary`, `SubscriptionInfo` (inkl. Nachfrist), `TrialPeriod` (30 Tage wie ELRDRG; dort war der Test faktisch abgeschaltet), `EntitlementResolver` (Abo vor Test, abgelaufen seit …), `EntitlementPolicy.standard` (ohne Abo bleiben Ansehen und Export erlaubt – Vorschlag, endgültig in Schritt 51, E42), `EntitlementProvider` (MainActor) + `StaticEntitlements` (Entwicklung/Vorschau/Tests), `FeatureLockedError`. `MissionCommand.requiredFeature` (Standard `.missionEditing`); `MissionStore.create`/`perform` prüfen zentral, `isEnabled(_:)` für die Oberfläche. Ohne Angabe nutzt der Store `StaticEntitlements.development()` (alles frei bis Schritt 51). Produkt-IDs werden erst mit StoreKit festgelegt (neue App → neue IDs). 8 Freischaltungs-Tests, 13 Store-Tests.
- **Schritt 14 (2026-10-29):** `ELRDFeatures/DesignSystem`: `Spacing` (4-pt-Raster), `Radius`, `TouchTarget` (44/56 pt), `Surface` (System-Hintergründe), `.cardStyle()`, `Color(RGBColor)`, `Color.triage/onTriage/registration`; `TriageBadge` (klein/normal/groß, Rand für „unverletzt“ und „verstorben“, VoiceOver-Text) und `TriageSummaryView` (SK 1–3 immer, Rest bei Bedarf; weicht bei Platzmangel auf Raster aus). `Workspace/`: `WorkspaceSection` (7 Bereiche, Symbol, ⌘1–⌘7, geplanter Schritt), `WorkspaceBadges` (offene Patienten = nicht entlassen/nicht im Transport, ungelesene Nachrichten), `ElapsedTimeFormat` („1 T 2:05 h“), `MissionWorkspaceView` (`NavigationSplitView`, Seitenleiste mit Einsatzkopf inkl. minütlicher Laufzeit und SK-Zählern; Detail mit Platzhaltern je Bereich, vorläufige Übersicht), `WorkspaceCommands` (Menü „Einsatz“ über `FocusedValue` je Fenster) – in `ELRDApp` eingebunden. `RootView` startet vorerst mit `PreviewData` (nichts wird gespeichert). **Akzentfarbe Blau** (hell #1F5FAD / dunkel #5C9DFF) statt Rot – Rot bleibt SK 1 vorbehalten (E44). **CI erzeugt jetzt Bildschirmfotos** (iPad Pro 13″, hell + dunkel) und legt sie im Branch `ci-screenshots` ab; prüfen mit `git clone --depth 1 -b ci-screenshots https://github.com/Jonas112/elrd <ordner>` und die PNGs ansehen. Lauf dauert dadurch ~4 min. Test-Target `ELRDFeaturesTests` (7 Tests). Hinweis: Parametrisierte Testargumente fest typisieren, sonst Compiler-Zeitlimit.
