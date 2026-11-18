# HIG-Prüfung (2026-11-18)

Prüfung der Oberfläche (`ELRDKit/Sources/ELRDFeatures`) gegen Apples Human Interface Guidelines. Grundlage ist der Code auf Stand `5b0a6d3`; es lagen keine aktuellen Bildschirmfotos vor. Kontraste wurden aus den Hex-Werten berechnet (WCAG-Formel), bei Systemfarben mit Apples dokumentierten Werten. Zeigereffekte, VoiceOver-Reihenfolge und Voice Control sind nur auf dem Gerät prüfbar.

Die Befunde sind als Schritte 146–150 in `FORTSCHRITT.md` eingeplant.

## Befunde

| # | Schwere | Befund | Richtlinie | Schritt |
|---|---|---|---|---|
| 1 | Kritisch | Nachtmodus legt `Color.black.opacity(0.35)` über die ganze App (`RootView.swift`, `DisplayModeModifier`). Sekundärer Text im Dunkelmodus fällt von 5,9:1 auf 3,1:1, tertiärer von 2,5:1 auf 1,65:1; „Kontrast erhöhen“ hilft nicht. | `accessibility.md › Color and effects`: Text bis 17 pt mindestens 4,5:1 | 146 |
| 2 | Hoch | 59 Stellen mit `.foregroundStyle(.orange)` (oft Fehlermeldungen in Formularen) und 10 mit `.green`. Systemorange auf Weiß 2,2:1, auf gruppiertem Hintergrund 2,0:1; Systemgrün auf Weiß 2,2:1. Dunkel: Orange 8,3:1 (in Ordnung). | `accessibility.md`: 4,5:1; formal nur erfüllt, weil Systemfarben unter „Kontrast erhöhen“ dunkler werden | 147 |
| 3 | Mittel | App-eigene Darstellungseinstellung: Nachtmodus setzt `preferredColorScheme(.dark)` (`SettingsView.swift`). | `dark-mode.md › Best practices`: „Avoid offering an app-specific appearance setting.“ | 146, Frage an Jonas |
| 4 | Mittel | Sichtbarer Text und Bedienungshilfen-Name weichen ab: „Meldungen“ ↔ „Benachrichtigungen“ (`MessagesBellButton`), „Einsätze“ ↔ „Einsatz verlassen, zurück zur Einsatzliste“ (`WorkspaceRail`). Voice Control („Tippe Meldungen“) trifft nichts. | `accessibility.md › Interactions` (Voice Control: Elemente passend beschriften) | 148 |
| 5 | Mittel | Eigene Bereichsleisten (`WorkspaceRail`, `WorkspaceTabBar`, E56) ohne Tab-Semantik: VoiceOver sagt nicht „Tab, 2 von 5“. Auf dem iPad mini hoch liegt die Leiste unten, das System setzt sie auf dem iPad oben. | `tab-bars.md › Tablet (iPadOS)`: „Prefer a tab bar for navigation.“ | 148 |
| 6 | Mittel | Eigene Farben ohne Variante für „Kontrast erhöhen“: `AccentColor` (Asset), `ActionFill.primary`, `ActionFill.selected`. Akzent auf ausgewähltem Hintergrund 4,2:1 (hell) / 4,3:1 (dunkel); Weiß auf `ActionFill` 6,4:1 / 4,8:1. | `color.md › Best practices`: „an increased contrast option for each variant“ | 149 |
| 7 | Niedrig | Hinweisfenster mit Titel „Hinweis“ (`ReportEditorView`, `MissionListView`); „Einsatz übernommen“ als reines Info-Fenster. | `writing.md` (klare Meldungen), `feedback.md`: Hinweisfenster nur für wichtige, möglichst handlungsrelevante Information | 150 |
| 8 | Niedrig | Kein `.hoverEffect` im ganzen Code; ob `.plain`-Knöpfe mit Trackpad hervorgehoben werden, ist auf dem Gerät zu prüfen. | `pointing-devices.md` | 150 |

## Was gut ist (beibehalten)
- `TouchTarget` 44/56/72 pt, im Handschuhmodus ×1,3 – über dem HIG-Standard (44 pt).
- Textstile statt fester Größen; feste Größen nur bei großen Ziffern/Symbolen ≥ 22 pt. Bereichstitel wachsen nicht mit – laut `typography.md` richtig.
- SK-Kennfarben mit berechneter Schriftfarbe (SK1 5,0:1, SK2 12,9:1, SK3 5,1:1, ungesichtet 8,1:1), Rand bei „unverletzt“ (1,3:1 zu Weiß) und „verstorben“ (1,06:1 zu Dunkel). SK nie nur über Farbe, immer mit Kürzel.
- Rückgängig-Leiste statt Rückfragen, „Bewegung reduzieren“ berücksichtigt, Leerzustände mit nächster Aktion, Systemhintergründe, Tastaturkürzel ⌘1–5, ⌘K, ⇧⌘P.
- Lageleiste mit SK-Zählern als einziges kräftiges Element, Rest ruhig – passt zu `branding.md`.
