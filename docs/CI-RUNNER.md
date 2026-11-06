> **Nicht mehr in Gebrauch (E72):** Das Repo ist öffentlich, die CI läuft wieder auf GitHub-Runnern. Ein eigener Runner an einem öffentlichen Repo ist unsicher. Nur verwenden, falls das Repo wieder privat wird.

# CI auf dem eigenen Mac (Self-hosted Runner)

Seit 2026-11-05 laufen Build, Tests und Bildschirmfotos auf Jonas' Mac statt auf GitHub-Servern (E71). Grund: Die freien macOS-Minuten waren aufgebraucht, denn macOS-Läufe zählen bei GitHub mehrfach.

## Einmalig einrichten (ca. 10 Minuten)

1. **Xcode vorbereiten**
   - Xcode 26.6 einmal öffnen und die Zusatzkomponenten installieren lassen.
   - Unter Xcode → Settings → Components muss eine iOS-26-Simulator-Laufzeit vorhanden sein.
   - Die Simulatoren „iPad Pro 13-inch (M5)“ und „iPad mini (A17 Pro)“ (oder ähnlich) anlegen, falls sie fehlen: Window → Devices and Simulators → Simulators → „+“.
   - Im Terminal: `sudo xcodebuild -runFirstLaunch`
2. **Runner bei GitHub anlegen**
   - github.com/Jonas112/ELRD → Settings → Actions → Runners → **New self-hosted runner**.
   - Betriebssystem **macOS** wählen, Architektur **ARM64** (Apple-Chip) bzw. x64.
   - Die angezeigten Befehle im Terminal ausführen, am besten in einem eigenen Ordner wie `~/actions-runner`: herunterladen, entpacken, `./config.sh --url … --token …`.
   - Bei den Fragen von `config.sh` überall Enter drücken. Die Standard-Labels `self-hosted, macOS` passen zum Workflow.
3. **Runner dauerhaft starten**, im selben Ordner:
   ```
   ./svc.sh install
   ./svc.sh start
   ```
   Der Runner läuft dann im Hintergrund, solange du angemeldet bist, und startet nach einem Neustart automatisch mit.
4. **Ruhezustand verhindern**, während Claude arbeitet: Systemeinstellungen → Energie (bzw. Batterie → Optionen) → „Automatischen Ruhezustand verhindern, wenn der Bildschirm aus ist“ (am Netzteil).

Ob der Runner läuft, siehst du unter Settings → Actions → Runners: Er sollte als **Idle** (grün) erscheinen.

## Gut zu wissen

- Ist der Mac aus oder schläft er, warten die Läufe in der Warteschlange, maximal 24 Stunden. Sie starten, sobald der Mac wieder erreichbar ist.
- Während eines Laufs startet Xcode Simulatoren. Der Mac ist dann ein paar Minuten beschäftigt. Am Ende werden alle Simulatoren beendet.
- Gebaut wird im Ordner `ELRD-DerivedData` neben dem Arbeitsordner des Runners. Den Ordner kannst du jederzeit löschen, dann dauert der nächste Lauf etwas länger.
- Bildschirmfotos entstehen nur, wenn die Commit-Nachricht `[fotos]` enthält oder der Lauf über „Run workflow“ gestartet wird.
- Zurück auf GitHub-Server: in `.github/workflows/build.yml` die Zeile `runs-on: [self-hosted, macOS]` durch `runs-on: macos-26` ersetzen.
- Runner entfernen: `./svc.sh stop`, `./svc.sh uninstall`, `./config.sh remove --token …` (das Token steht auf der Runner-Seite bei GitHub).
