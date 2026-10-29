# Funktionsinventar ELRDRG → ELRD

Quelle: `Jonas112/ELRDRG`, Commit `96a0939` (2026-05-11), iPad-only, UIKit + Storyboards, Core Data, iPadOS 16.4.
Ziel: `Jonas112/ELRD`, neue App, SwiftUI, iPadOS 17+.

Spalte **Neu** verweist auf die Schrittnummer in `FORTSCHRITT.md`.
Status: ✅ übernehmen · 🔁 übernehmen und neu gedacht · ⏳ später · ❌ entfällt

## Einsätze

| Funktion | Alt (Datei) | Neu | Status |
|---|---|---|---|
| Einsatzliste, Auswahl, Löschen | `StartVC`, `DataHandler.getAllMissions` | 16 | ✅ |
| Filter „nur aktuelles Jahr“ / „alle Einsätze anzeigen“ | `StartVC.filterMissionsbyYear`, `Settings.showAllMissions` | 16 | ✅ |
| Neuer Einsatz (optional direkt mit Audioaufnahme starten) | `DataHandler.addMission`, `Settings.startWithAudioRecorder` | 16, 35 | ✅ |
| Einsatzdaten: Grund, Einsatzart, Ort, Beginn/Ende, Einsatznummer, Jahresnummer, km Anfang/Ende, Einsatzleiter | `ChangeMissionVC`, `iMissionMetaDataCVC`, `Mission` | 17 | ✅ |
| Einsatzarten (Brand, BMA, VU, Gefahrgut, Polizei-Sonderlage, Vermisstensuche, Berg-, Wasserrettung, Mehrfach erkrankt, Sonstiges) | `StatisticHandler.MissionType` | 3 | ✅ |
| Einsatz beenden | `UebersichtVC.endMission_Click`, `DataHandler.setEndDate` | 17 | ✅ |
| Testdaten im Simulator | `SimulatorDataHandler` | 10 | 🔁 als Preview-/Testdaten |

## Patienten

| Funktion | Alt | Neu | Status |
|---|---|---|---|
| Patientenliste mit Schnellanlage je SK (1, 2, 3, ungesichtet) | `PatientenVC` | 18 | ✅ |
| Sortierung nach SK / Nummer | `PatientenVC.sort` | 18 | ✅ |
| Grafik-/Kachelansicht | Storyboard-Tab „Grafik“, `PatientCVC` | 23 | ✅ (Details beim Schritt prüfen) |
| Sichtungskategorien SK 1, 2, 3, unverletzt, ungesichtet, verstorben inkl. Farben | `Sichtungskategorie` | 3 | ✅ |
| Personendaten: Vor-/Nachname, Alter, Geburtsdatum (Alter berechnet), Kind, Geschlecht (m/w/unklar) | `PatientenDetailVC` | 19 | ✅ |
| Patientennummer + ILS-Nummer mit Dublettenprüfung | `Victim.checkDoublePatID`, `patILSNR` | 19 | 🔁 mehrbenutzerfest |
| Zusatzinformationen (Freitext) | `additionalIfnormation` | 19 | ✅ |
| Verletzungen aus Stammdaten, Lokalisation + Seite, neue Diagnose anlegen | `SelectInjuryVC`, `InjuryHandler` | 20 | ✅ |
| IVENA: RMI-Auswahl, Behandlungspriorität, PZC-Berechnung | `IVENA`, `IVENABayern`, `Victim.getPZC` | 21 | ✅ |
| Schockraum (keiner/A/B), intubiert, stabil | `Victim` | 21 | ✅ |
| Zielklinik, Anmeldestatus (unklar, angefragt, angemeldet, nicht angefragt) | `hospitalInfoState` | 22 | ✅ |
| Transportmittel (Einheit), Transport starten (Zeitstempel), Entfernung zur Klinik | `startTransport_Click`, `LocationHandler` | 22 | ✅ |
| Mail zu Patient | `PatientenDetailVC.SendMail` | 46 | 🔁 über Berichtsausgabe |
| Klinikbericht mit ausgewählten Tagebucheinträgen | `SelectDocuEntryViewController` | 45 | 🔁 als Berichtsvorlage |

## Organisation

| Funktion | Alt | Neu | Status |
|---|---|---|---|
| Abschnitte anlegen (aus Stammdaten oder frei), Standardabschnitte automatisch | `SectionHandler`, `Settings.add_standard_sections_automatically` | 24 | ✅ |
| Neue Abschnitte dauerhaft in Stammdaten übernehmen | `Settings.safe_new_sections_permanent` | 24 | ✅ |
| Einheiten aus Stammdaten zuweisen, freie vs. eingesetzte Einheiten | `UnitHandler.getUnusedBaseUnits` | 25 | ✅ |
| Temporäre Einheit anlegen (optional dauerhaft speichern) | `CreateTempObjectViewController`, `Settings.safedynCreatedUnit` | 25 | ✅ |
| Einheitentypen RTW, KTW, NEF, RTH, Sonstiges, Krad, KdoW, MTW, LKW, KTW-KatS, Wasserwacht, ELW | `UnitHandler.UnitType` | 3 | ✅ |
| Platzhalter-Einheiten (RTW/KTW/NEF) | `createDummyUnit` | 26 | ✅ |
| Alarmstichworte RD 1–5 (erzeugen Platzhalter) | `UnitHandler.Alarmstichwort` | 26 | ✅ |
| Platzhalter durch reale Einheit ersetzen | `ReplaceDummyViewController` | 26 | ✅ |
| Gruppierung von Patienten pro Transportmittel | `UnitPattern` | 25 | ✅ |
| Drag & Drop Einheit → Abschnitt, Patient → Einheit | `AbschnitteVC` | 27 | ✅ |
| Filter nach Typ, Suche | `AbschnitteVC.filterByType`, `filterbySearchbar` | 25 | ✅ |

## Lagekarte

| Funktion | Alt | Neu | Status |
|---|---|---|---|
| Karte mit Standort, Kartendienste Apple / OpenStreetMap / OpenTopoMap, Maßstab | `MapVC`, `MapProvider` | 28 | ✅ |
| Abschnitte per Drag oder Long-Press auf Karte setzen, verschieben, entfernen | `MapVC.DroppedSectionToMap`, `handleLongPress` | 29 | ✅ |
| Kreis- und Rechteck-Overlays, Overlay-Liste | `CircleMapOverlay`, `RectangleMapOverlay`, `overlayListViewController` | 30 | ✅ |
| Freihandzeichnung als Overlay | `MapDrawingOverlay`, `MapVC.draw` | 31 | ✅ |
| Kartenausschnitt ins Tagebuch, Karte drucken | `createScreenShotToDocu`, `printMap` | 32 | ✅ |
| what3words | `addW3W` (Paket `w3w-swift-components`) | 32 | ⏳ optional, API-Schlüssel nötig |

## Tagebuch, Nachrichten, Protokoll

| Funktion | Alt | Neu | Status |
|---|---|---|---|
| Texteintrag mit Datum | `DocumentationHandler.SaveTextDocumentation` | 33 | ✅ |
| Textvorlagen mit Nutzungszähler | `DocumentationTemplate` | 33 | ✅ |
| Fotoeintrag (Kamera/Fotos), Bearbeiten | `DocumentationDetailPhotoVC` | 34 | ✅ |
| Audioeintrag (Aufnahme/Wiedergabe) | `DocumentationDetailAudioVC` | 35 | ✅ |
| Nachrichten mit „gelesen“, Badge | `Notification`, `NotificationsViewController` | 36 | ✅ |
| Systemprotokoll pro Einsatz (automatisch bei Aktionen) | `NSObject.log`, `Log`, `LoggingsViewController` | 10, 36 | 🔁 aus Änderungsjournal abgeleitet |

## Übersicht & Export

| Funktion | Alt | Neu | Status |
|---|---|---|---|
| Einsatzübersicht (Patienten, Einheiten, Tagebuch) | `UebersichtVC` | 37 | ✅ |
| PDF-Export Kapitel: Kopf, Einsatzinfo, Organisation, Patienten, Tagebuch, Protokoll, Fuß | `ViewController/Export/*` (TPPDF) | 38–46 | 🔁 neue Engine, frei konfigurierbare Berichte |
| Mail an ILS | `ExportVC.SendMailToILS`, `Settings.ils_mailAdress` | 46 | ✅ |
| Teilen / Speichern | `ExportVC.openActivity` | 46 | ✅ |
| Alter HTML-Export (10.000 Zeilen) | `Export/OLD/*` | – | ❌ ersetzt |

## Einstellungen & Stammdaten

| Funktion | Alt | Neu | Status |
|---|---|---|---|
| Allgemeine Schalter (ILS-Mail, Abschnitts-Automatik, Anzeige, Audio beim Start) | `GeneralSettingsVC` | 47 | ✅ |
| Fahrzeugbilder (RTW/KTW/NEF/RTH) und Banner für Berichte | `IconSettingVC`, `Settings.image*` | 47 | ✅ |
| Stammdaten CRUD: Einheiten, Kliniken, Diagnosen, Abschnitte, Textvorlagen, Benutzer | `StammdatenDetailVC` u. a. | 48 | ✅ |
| Regionsimport per CSV (Rhön-Grabfeld, Aschaffenburg, Coburg, Dachau, Kempten, Schweinfurt, Allgemein) | `Stammdaten/*` | 11 | ✅ umgesetzt, Daten korrigiert |
| IVENA-Einstellungen | `IVENA_Einstellungen_SWUI` | 49 | ✅ |
| Lokale Benutzer mit Passwort, Admin, Anmelden/Abmelden | `LoginHandler`, `User` | 12, 15 | 🔁 Passwort gehasht + Keychain |
| Onboarding | `ModernOnboarding*` | 50 | ✅ |
| Nutzungs- und Datenschutzvereinbarung mit Datum | `AgreementHandler` | 50 | ✅ |
| Abo (Monatsabo, Testzeitraum, Wiederherstellen) | `SubscriptionManager`, `FunctionManager` | 13, 51 | 🔁 StoreKit 2, Entitlement-Schicht |

## Entfällt vorerst (Entscheidung 2026-10-17)

| Funktion | Alt | Grund |
|---|---|---|
| HTTP-Server im Gerät | `HttpServer.swift` | bereits auskommentiert |
| Schichten | `Shift` | nicht verwendet |
| Statistik | `StatisticHandler` | nicht angebunden |
| REST-Client / Server-Login | `Experimental/RESTFullApi`, `StammdatenServerViewController` | unfertig; Backend kommt über Sync-Schicht |
| Taktische Zeichen | `TaktischeZeichen/*` | nicht angebunden |
| Scratchpad | `ScratchView/*`, `Mission.scratchpadData` | nicht angebunden |
| Datenmigration aus ELRDRG | – | neue App |
