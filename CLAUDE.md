# Hinweise für Claude

Neubau der iPad-App ELRDRG (Einsatzleiter Rettungsdienst) in SwiftUI. Altes Projekt zum Nachschlagen: `Jonas112/ELRDRG`.

## Vor jeder Sitzung
1. `docs/FORTSCHRITT.md` lesen: dort stehen der nächste Schritt und die Übergabenotizen.
2. `docs/ARCHITEKTUR.md` und `docs/ENTSCHEIDUNGEN.md` beachten. Abweichungen nur nach Rückfrage bei Jonas und mit neuem Eintrag in `ENTSCHEIDUNGEN.md`.
3. Bei Unsicherheit fachlich nachfragen statt raten.

## Arbeitsweise
- Ein Schritt pro Sitzung, klein halten. Am Ende: Status und Übergabenotiz in `FORTSCHRITT.md`, dann commit und push auf `main`.
- In der Cloud-Umgebung gibt es kein Xcode. Nach jedem Push den CI-Lauf prüfen: `gh run list -R Jonas112/ELRD`, `gh run watch <id> --exit-status`, `gh run view <id>` (Fehler stehen als Annotationen). Erst bei grünem Build ist ein Schritt fertig.
- CI läuft auf GitHub-Runnern (`macos-26`, Repo ist öffentlich, E72). Keinen Self-hosted Runner verwenden, solange das Repo öffentlich ist.
- Oberflächen per Bildschirmfoto prüfen: Fotos entstehen nur mit `[fotos]` in der (letzten) Commit-Nachricht – bei jeder Änderung an Oberflächen anhängen. Laden mit `gh api -H "Accept: application/vnd.github.raw" "repos/Jonas112/ELRD/contents/<name>.png?ref=ci-screenshots"` (hell und dunkel).
- Kommunikation, Kommentare und Dokumentation auf Deutsch. Bezeichner im Code auf Englisch, Fachbegriffe (Sichtungskategorie, Alarmstichwort) dürfen deutsch bleiben, wenn sie keine gute Übersetzung haben.

## Regeln im Code
- Views schreiben nie direkt in die Persistenz, nur über Commands (`MissionStore`).
- Jede Entität: `UUID`-ID, `missionID` falls einsatzbezogen, Metadaten für Version/Autor, Soft-Delete.
- Keine externen Abhängigkeiten.
- iPadOS 17 als Mindestversion; neuere APIs nur mit `#available`.
- Keine Klartext-Passwörter, keine personenbezogenen Daten in Logs.
