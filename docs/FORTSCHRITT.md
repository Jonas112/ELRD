# Fortschritt

**Nächster Schritt:** 4 – Domäne 2: Einsatz, Abschnitt, Einheit
**Weitermachen:** In einer neuen Sitzung „weiter mit Schritt N“ schreiben. Claude liest zuerst diese Datei, `ARCHITEKTUR.md` und `ENTSCHEIDUNGEN.md`.

Ablauf je Schritt: Claude schreibt Code, committet und prüft den CI-Build (GitHub Actions) selbst → Fehler behebt Claude im selben Schritt. Jonas testet zusätzlich auf dem Gerät.
Status: ⬜ offen · 🔨 in Arbeit · 🧪 wartet auf Build in Xcode · ✅ fertig

## A – Fundament
| # | Schritt | Status |
|---|---|---|
| 1 | Analyse, Funktionsinventar, Architektur, Entscheidungen | ✅ |
| 2 | Projektgerüst: Xcode-Projekt (iPad, iPadOS 17), lokales Package `ELRDKit` mit Modulen, CI-Build | ✅ |
| 3 | Domäne 1: Werttypen & Enums (SK, Einheitentyp, Alarmstichwort, Einsatzart, Geschlecht, Schockraum, Klinikstatus, IVENA) | ✅ |
| 4 | Domäne 2: Einsatz, Abschnitt, Einheit | ⬜ |
| 5 | Domäne 3: Patient, Verletzung, Klinik | ⬜ |
| 6 | Domäne 4: Tagebuch, Anhang, Nachricht, Protokoll, Kartenobjekte | ⬜ |
| 7 | Sync-Metadaten, Änderungsjournal, HLC-Zeitstempel, Patientennummern-Vergabe | ⬜ |
| 8 | SwiftData-Schema und Mapping | ⬜ |
| 9 | Repositories (SwiftData + In-Memory) | ⬜ |
| 10 | Command-Schicht und `MissionStore`, Protokoll aus Journal, Testdaten | ⬜ |
| 11 | Stammdatenmodell und CSV-Regionsimport | ⬜ |
| 12 | Benutzer & Anmeldung: Passwort-Hash, Keychain, `AuthProvider`, Konto-Verknüpfung vorbereitet | ⬜ |
| 13 | Freischaltungs-Schicht (Entitlements) für späteres Abo | ⬜ |
| 14 | App-Rahmen: adaptive Navigation, Designsystem, Tastaturkürzel-Grundlage | ⬜ |

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
