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
