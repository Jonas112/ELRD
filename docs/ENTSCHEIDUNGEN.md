# Entscheidungen

Jede Entscheidung mit Datum. Neue Einträge unten anfügen, alte nicht löschen, sondern als „ersetzt durch …“ markieren.

| # | Datum | Entscheidung | Begründung |
|---|---|---|---|
| E1 | 2026-10-17 | Neues Repo `Jonas112/ELRD`, neue App (keine Fortführung von ELRDRG, keine Datenmigration) | Sauberer Neustart in SwiftUI |
| E2 | 2026-10-17 | Mindestversion iPadOS 17.0, iPad only | SwiftData, `@Observable`; iPadOS-18-Funktionen nur optional |
| E3 | 2026-10-17 | Entfällt vorerst: HTTP-Server, Schichten, Statistik, REST-Client, Taktische Zeichen, Scratchpad | Nicht angebunden bzw. unfertig im Altprojekt |
| E4 | 2026-10-17 | Abo kommt später (StoreKit 2), Architektur bekommt sofort eine Freischaltungs-Schicht | Später ohne Umbau integrierbar |
| E5 | 2026-10-17 | Lokale Benutzer mit Passwort bleiben; Backend optional und mit lokalem Konto verknüpfbar | Offline-Betrieb im Einsatz, Backend kein Muss |
| E6 | 2026-10-17 | Passwörter nur als PBKDF2-Hash, nie im Klartext | DSGVO; Altprojekt speicherte Klartext |
| E7 | 2026-10-17 | PDF: eigene Engine ohne TPPDF, frei konfigurierbare Berichtsvorlagen | Layout/Design und fehlende Steuerbarkeit waren die Hauptkritik |
| E8 | 2026-10-17 | Keine externen Abhängigkeiten, nur Systemframeworks | Wartbarkeit, App-Review, Datenschutz |
| E9 | 2026-10-17 | UUID-Schlüssel, Versions-/Autor-Metadaten, Soft-Delete und Änderungsjournal ab dem ersten Datenmodell | Mehrbenutzer-Modus später ohne Datenmodell-Umbau |
| E10 | 2026-10-17 | Domain als reine Werttypen, SwiftData nur in der Persistenzschicht | Austauschbarkeit, Testbarkeit, Codable-DTOs für Sync |
| E11 | 2026-10-17 | Xcode 26.6, Projektformat mit synchronisierten Ordnern; Logik im lokalen Package `ELRDKit` | Neue Dateien ohne Eingriff in die Projektdatei |
| E12 | 2026-10-17 | Swift-5-Sprachmodus mit `StrictConcurrency` und `ExistentialAny` | Concurrency-Sicherheit ab Start, Swift-6-Umstieg später ohne Umbau |
| E13 | 2026-10-17 | Tests mit Swift Testing; CI-Build auf GitHub Actions (`macos-26`) nur bei Code-Änderungen | Claude kann ohne Xcode Build-Ergebnisse prüfen; macOS-Minuten sparen |
| E14 | 2026-10-18 | Enum-Rohwerte (SK 1–6, Einheitentyp 0–11, Geschlecht, Schockraum, Klinikstatus, IVENA-Priorität, Einsatzart-Texte) unverändert aus ELRDRG | Null-Transformation zum ELRD-Backend, späterer Import alter Daten möglich |
| E15 | 2026-10-18 | SK 2 in Gelb (statt Orange wie in ELRDRG), Farben als `RGBColor` in der Domäne | Übliche Farbkodierung; App und PDF nutzen dieselben Farben |
| E16 | 2026-10-18 | Domänentypen `MissionSection` und `MissionUnit` statt `Section`/`Unit` | Namenskonflikte mit `SwiftUI.Section` und `Foundation.Unit` |
| E17 | 2026-10-18 | ILS-Einsatznummer als Text (`dispatchNumber: String?`), km-Stände als Ganzzahl | Leitstellenformate mit Buchstaben/führenden Nullen; ELRDRG speicherte Int32 |
| E18 | 2026-10-18 | Platzhalter-Nummern fortlaufend je Einsatz über alle Typen; Anzeige „RTW (Platzhalter 3)“ | Verhalten wie ELRDRG („Dummy (3) RTW“), verständlicher benannt |
| E19 | 2026-10-18 | Verletzungen eingebettet im Patienten, je Eintrag eigene `InjuryID` | Einfacher Zugriff; Sync kann trotzdem einzelne Einträge zusammenführen |
| E20 | 2026-10-18 | Zielklinik als Momentaufnahme (`HospitalSnapshot`) statt Verweis | Stammdaten-Änderungen verändern keine alten Einsätze/Berichte |
| E21 | 2026-10-18 | Patientennummer ist Anzeige, Dubletten werden markiert statt blockiert | Im Einsatz nicht durch Validierung aufhalten; Schlüssel ist die UUID |
| E22 | 2026-10-18 | Anhangstyp heißt `FileAttachment` | Konflikt mit `Testing.Attachment` (und generell zu allgemein) |
| E23 | 2026-10-18 | Kreislauf mit drei Zuständen (`CirculationState`) | Wunsch Jonas: „nicht beurteilt“ von „stabil“ unterscheiden |
| E24 | 2026-10-18 | Kartengeometrie in geografischen Koordinaten (`GeoBounds`), nicht `MKMapRect` | Plattformunabhängig, für Sync und PDF nutzbar |
| E25 | 2026-10-18 | Protokolltexte nennen Patienten nur per Nummer | Datenschutz: Protokoll/Logs ohne Namen |
| E26 | 2026-10-18 | Patienten- und Tagebuchnummern mit Gerätepräfix („A-12“), Standardpräfix „A“ | Entscheidung Jonas: offline auf mehreren Geräten eindeutig, auf Anhängekarten lesbar |
| E27 | 2026-10-18 | Konfliktlösung: HLC-Zeitstempel, „letzter Schreiber gewinnt“ je Feld; Listen mit Kennungen elementweise | Gleichzeitige Änderungen an verschiedenen Feldern/Listenelementen gehen nicht verloren; Ergebnis unabhängig von der Empfangsreihenfolge |
| E28 | 2026-10-21 | SwiftData nur mit zwei flachen Tabellen (`EntityRecord` mit JSON-Inhalt, `ChangeRecord`), keine Beziehungen | Umgeht bekannte SwiftData-Probleme mit Beziehungen unter iPadOS 17, gleiches JSON wie Sync, neue Felder ohne Migration; Filter auf Feldebene im Speicher (Datenmenge je Einsatz klein) |
| E29 | 2026-10-21 | Dateischutz `completeUntilFirstUserAuthentication` für die Datenbank | DSGVO-Schutz im Ruhezustand, Speichern bleibt bei gesperrtem Gerät möglich |
| E30 | 2026-10-22 | Schreiben nur über atomare `ChangeSet`s; ein älterer Stand darf keinen neueren überschreiben (`staleWrite`) | Mehrere iPad-Fenster bzw. später mehrere Geräte; keine halb gespeicherten Aktionen |
| E31 | 2026-10-22 | Repositories laufen auf dem Main Actor | SwiftData-Kontexte sind nicht threadsicher; Datenmengen klein genug für den Main Thread |
| E32 | 2026-10-22 | Eigenes Modul `ELRDStore` für Commands und `MissionStore` (ohne SwiftUI) | Ablauflogik ohne Oberfläche testbar; `ELRDFeatures` bleibt reine Darstellung |
| E33 | 2026-10-22 | Protokoll wird von den Commands als lesbarer Eintrag geschrieben, nicht aus dem Änderungsjournal abgeleitet | Verständliche Texte („Patient A-1: SK 2 → SK 1“); Journal bleibt technisch für Sync |
| E34 | 2026-10-22 | Bei Konflikt durch ein anderes Fenster: neu laden und Aktion einmal wiederholen | Aktionen sind Absichten; Benutzer muss nicht erneut tippen |
| E35 | 2026-10-29 | Stammdaten als ein Dokument (`MasterDataSet`) mit Revision, ohne Metadaten je Eintrag | Ändern sich selten, werden als Ganzes importiert und später mit dem Backend abgeglichen (dort ebenfalls ganz oder gar nicht) |
| E36 | 2026-10-29 | Schema V1 um `DocumentRecord` erweitert statt V2 | App noch nicht veröffentlicht; ab erster Veröffentlichung nur noch neue Schemaversionen |
| E37 | 2026-10-29 | Regionspakete in die App eingebettet, Import mit Dublettenprüfung; Kliniken Unterfranken als eigenes Paket statt automatisch für Schweinfurt/Kempten | Nachvollziehbar, was importiert wird; Kempten bekam in ELRDRG unpassend die unterfränkische Liste |
| E38 | 2026-10-29 | Fahrzeugtypen vollständig zuordnen, Originalbezeichnung behalten | ELRDRG legte HVO, MZF, Kat-KTW, MTW, LKW … als „Sonstiges“ an |
| E39 | 2026-10-29 | Passwort mind. 6 Zeichen ohne Zeichenklassen-Pflicht; Sperre nach 5 Fehlversuchen (30 s, verdoppelnd bis 15 min) | Schnelle Eingabe im Einsatz; Schutz über Hash, Sperre und iPad-Gerätesperre |
| E40 | 2026-10-29 | Administratoren immer mit Passwort, Einsatzleiter optional ohne | Gemeinsam genutzte Einsatz-iPads; Verwaltungsrechte bleiben geschützt |
| E41 | 2026-10-29 | Benutzer werden deaktiviert, nicht gelöscht; der letzte aktive Admin ist geschützt | Namen in Einsätzen/Berichten bleiben erhalten; Gerät kann nicht ohne Admin enden |
| E42 | 2026-10-29 | Ohne Abo: Einsätze ansehen und exportieren bleibt möglich, Anlegen/Bearbeiten gesperrt (Vorschlag, endgültig in Schritt 51) | Zugriff auf eigene Daten und Dokumentationspflicht; DSGVO |
| E43 | 2026-10-29 | Freischaltung wird im `MissionStore` geprüft, nicht nur in der Oberfläche | Sperre kann nicht durch eine vergessene Oberflächenprüfung umgangen werden |
| E44 | 2026-10-29 | Akzentfarbe Blau; Rot, Gelb, Grün nur für Sichtungskategorien | Farbbedeutung im Einsatz eindeutig; rote Auswahl wirkte wie Alarm |
| E45 | 2026-10-29 | CI erstellt Bildschirmfotos hell/dunkel im Branch `ci-screenshots` | Oberflächen können ohne Xcode-Zugriff geprüft werden |
| E46 | 2026-10-29 | Startargument `--demo-screen` startet eine Beispielumgebung nur im Speicher (eigene Benutzer, schneller Hasher) | Reproduzierbare CI-Bildschirmfotos ohne Eingaben; echte Daten und Keychain bleiben unberührt |
| E47 | 2026-11-04 | ILS-Einsatznummer bleibt freier Text (Jonas bestätigt) | Formate der Leitstellen unterscheiden sich |
| E48 | 2026-11-04 | Doppelte Patientennummern werden nur als Hinweis angezeigt, nie blockiert (Jonas bestätigt) | Mehrere Geräte/Helfer vergeben Nummern; im Einsatz darf nichts sperren |
| E49 | 2026-11-04 | Region Schweinfurt erhält die Kliniken Unterfranken automatisch (Jonas bestätigt; so bereits umgesetzt, Kempten weiterhin nicht) | Präzisiert E37 |
| E50 | 2026-11-04 | IVENA bei Priorität 1: ABCD-Status je mit Stufe 1–4 (A Atemweg: frei/gefährdet/gesichert/kritisch-ungesichert · B Atmung: unbeeinträchtigt/beeinträchtigt/NIV/invasiv beatmet · C Kreislauf: stabil/stabil nach Kreislauftherapie/stabil unter Katecholaminen/instabil unter Therapie · D Bewusstsein: wach/getrübt/bewusstlos/sediert-narkotisiert) | Fachvorgabe Jonas; nur Zusatzinfo für die Kliniken, **kein Einfluss auf den PZC**; Kreislauf und „intubiert“ bleiben unabhängig davon erhalten; im UI ein Knopf je Buchstabe, Tippen öffnet die vier Stufen (Jonas, 2026-11-04) |
| E51 | 2026-11-04 | Laufende Einsätze stehen in der Einsatzliste immer oben, unabhängig von Jahresfilter und Suche | Nachts nie den eigenen Einsatz suchen müssen |
| E52 | 2026-11-04 | „Neuer Einsatz“ fragt nur Stichwort, Einsatzart, Ort, Meldebild, ILS-Nr.; Beginn = jetzt, Einsatzleiter = angemeldeter Benutzer; Stichwort-Platzhalter im selben Speichervorgang | Weniger ist mehr; Einsatz in Sekunden angelegt, alles Weitere später |
| E53 | 2026-11-04 | Einsätze werden weich gelöscht (mit Bestätigung, nur im Kontextmenü); Jahresnummern bleiben vergeben | Seltene, folgenreiche Aktion bewusst versteckt; Sync und Nachvollziehbarkeit |
| E54 | 2026-11-04 | Gefüllte Hauptknöpfe nutzen `ActionFill.primary` (#1F5FAD hell / #2F6FD6 dunkel), nicht die Akzentfarbe | Weiße Schrift auf #5C9DFF wäre zu kontrastarm |
| E55 | 2026-11-04 | Fünf Bereiche (Lage, Patienten, Einheiten, Karte, Tagebuch); Nachrichten als Glocke, Protokoll als Filter im Tagebuch | Weniger ist mehr; jeder Bereich mit einem Tipp erreichbar |
| E56 | 2026-11-04 | Schmale Symbolleiste links statt Seitenleiste; unter 800 pt Breite (iPad mini hoch, schmale Fenster) Leiste unten | Platz für Inhalt auf dem iPad mini; unten liegt sie am Daumen |
| E57 | 2026-11-04 | Feste Lageleiste in allen Bereichen: Laufzeit, SK-Zähler, „+ Patient“ mit Schnellanlage und Rückgängig statt Rückfrage | Neuer Patient ist überall zwei Tipps entfernt; Fehlgriffe ohne Dialog korrigierbar |
| E58 | 2026-11-04 | Lage zeigt „offene Punkte“ (dringendste zuerst, je mit Knopf) statt reiner Zahlen | Unter Stress sieht man sofort, was zu tun ist |
| E59 | 2026-11-04 | SK 3 #2E7D32 statt #388E3C; Klinik-Anmeldestatus ohne Rot (offen grau) | Kontrast weißer Schrift; Rot nur für SK 1 (E44) |
| E60 | 2026-11-05 | Formulare (Einsatzdaten, Patient) schreiben nur tatsächlich geänderte Felder; Patientendaten speichern automatisch ohne „Speichern“-Knopf | Keine verlorenen Änderungen anderer Fenster/Geräte; im Einsatz kein vergessenes Speichern |
| E61 | 2026-11-05 | Geburtsdatum wird als Text eingegeben (TT.MM.JJJJ, auch verkürzt), kein Datumsrad; ersatzweise geschätztes Alter | Schneller unter Stress; Geburtsdatum hat Vorrang |
| E62 | 2026-11-05 | Neues Feld „Erkennungsmerkmale / Fundort“ am Patienten, in Liste und Suche | Unbekannte Personen wiederfinden (Jonas) |
| E63 | 2026-11-05 | Verletzung erfassen: Region → (bei Extremitäten) Seite → Diagnose als Chip; Suche über alle, unbekannter Text als eigene Diagnose | Zwei bis drei Tipps statt langer Listen; nichts ist durch den Katalog blockiert |
| E64 | 2026-11-05 | Zielklinik-Vorschläge: im Einsatz bereits gewählte zuerst, dann nach Luftlinie zum Einsatzort | Bei mehreren Patienten meist dieselben Kliniken; nächste Klinik ohne Suchen |
| E65 | 2026-11-05 | „Transport starten“ erst mit zugeordneter Einheit; „Vor Ort entlassen“ fragt, ob die Zielklinik behalten wird; beides zurücknehmbar | Wie ELRDRG; Fehlgriffe unter Stress korrigierbar |
| E66 | 2026-11-05 | „Transport starten“ nur mit zugeordnetem Transportmittel (RTW, KTW, KTW-KatS, RTH); NEF, HvO usw. dürfen zugeordnet werden, reichen aber nicht (Jonas) | Präzisiert E65; offene Punkte zählen solche Patienten weiter als „ohne Transportmittel“ |
| E67 | 2026-11-05 | Schritt 23 umfasst Körpergrafik (Region und Seite mit einem Tipp, Markierung erfasster Verletzungen) und Kachelansicht der Patienten (Jonas) | Körpergrafik als SwiftUI-Formen statt Bild aus ELRDRG: skalierbar, hell/dunkel, keine Lizenzfrage |
| E68 | 2026-11-05 | Ohne Initialabschnitt wird ein neuer Abschnitt automatisch Initialabschnitt (abschaltbar beim Anlegen); gelöschte Abschnitte geben ihre Einheiten und Patienten an „Ohne Abschnitt“ ab, das als eigene Karte vorne erscheint | Neue Einheiten landen nie unsichtbar; nichts geht beim Löschen verloren (wie ELRDRG, dort aber ohne Anzeige) |
| E69 | 2026-11-05 | Einheiten verschieben per Tipp → Menü „verschieben nach …“, zusätzlich später Ziehen (Schritt 27) | Ziehen ist auf dem iPad mini und unter Stress fehleranfällig; Menü funktioniert auch mit VoiceOver |
| E70 | 2026-11-05 | Einheiten: derselbe Funkrufname darf im Einsatz nur einmal vorkommen (temporäre Einheit wird abgelehnt, Stammdaten-Einheit übersprungen); Entfernen nur ohne zugeordnete, nicht entlassene Patienten | Anders als Patientennummern (E48) ist eine doppelte Einheit fast immer ein Fehlgriff; Transporte dürfen ihre Einheit nicht verlieren |
