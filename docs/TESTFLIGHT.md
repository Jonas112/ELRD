# TestFlight – Ablauf und Angaben

Stand: Schritt 57 (November 2026). Hochladen geht nur auf einem Mac mit Xcode und deinem Entwicklerkonto. Die Cloud-CI hat keine Zertifikate und kann deshalb nicht signieren.

## Vorbereitet im Projekt

- **App-Symbol:** das ELRD-Symbol aus ELRDRG (1024 × 1024, ohne Transparenz) in `ELRD/Assets.xcassets/AppIcon.appiconset`.
- **Version 2.0, Build 133.** Die alte App steht bei Version 1, Build 132. Für jeden weiteren Upload muss der Build um eins steigen (`CURRENT_PROJECT_VERSION`).
- **Datenschutz-Manifest** `ELRD/PrivacyInfo.xcprivacy`: kein Tracking, keine Datenerhebung. Begründete Schnittstelle: nur UserDefaults (CA92.1 – Daten nur innerhalb der App).
- **`ELRD-Info.plist`** (ergänzt die erzeugte Info.plist): `ITSAppUsesNonExemptEncryption = NO`, weil die App nur Apples Standard-Verschlüsselung nutzt. Damit entfällt die Exportfrage bei jedem Upload.
- **Berechtigungstexte:** Standort, Kamera, Mikrofon, lokales Netzwerk (Schritt 66).
- **StoreKit-Testdatei** `ELRD.storekit` im Schema (nur für den Simulator, wirkt nicht in TestFlight).

## Vor dem ersten Upload entscheiden (Jonas)

1. **Bundle-ID:** Im Projekt steht derzeit `ELRD.App`. Die alte App hat `ELRD.RescueCommander` (Team `2V6336KP7H`).
   - Soll ELRD 2.0 ein **Update der bestehenden App** werden, mit gleichem App-Store-Eintrag und bestehenden Abos? Dann muss die Bundle-ID auf `ELRD.RescueCommander` geändert werden.
   - Eine eigene ID ergibt eine **neue App**. Das Abo `ELRD.RescueCommander.BasisFunctionsMonthly` gehört aber zur alten App.
2. **Team:** In Xcode unter Signing & Capabilities das Team wählen, „Automatically manage signing“ an.
3. **In-App-Kauf:** Wenn die App einen neuen Eintrag bekommt, muss das Abo dort neu angelegt werden.

## Fähigkeiten, iCloud und CloudKit (Stand Schritt 120)

**Developer-Portal → Identifiers → `ELRD.App`** (macht Xcode mit automatischer Signierung meist selbst – trotzdem prüfen):
- iCloud: *CloudKit* **und** *iCloud Documents* (Schritt 120), Container `iCloud.ELRD.App` zugeordnet
- Push Notifications (stille Mitteilungen für den Abgleich)
- NFC Tag Reading (Schritt 110)
- Widget `ELRD.App.Widgets`: eigene App-ID, keine besonderen Fähigkeiten (Live Activity läuft über die App)

**Xcode → Ziel ELRD → Signing & Capabilities:** iCloud (CloudKit + iCloud Documents, Container `iCloud.ELRD.App`), Push Notifications, Background Modes → Remote notifications, Near Field Communication Tag Reading. `ELRD.entitlements` enthält das bereits; Xcode darf keine Fehler (rote Hinweise) zeigen.

**CloudKit-Konsole (icloud.developer.apple.com) → Container `iCloud.ELRD.App`:**
1. Einmal mit zwei Geräten in der Entwicklungsumgebung teilen, beitreten, Beitritt anfragen/zulassen – das legt die Datensatztypen an (`ELRDEvent`, `ELRDFile`, `ELRDJoinRequest`, `ELRDJoinDecision`). Alternativ in *Schema → Record Types* von Hand anlegen.
2. *Schema → Indexes*: `ELRDJoinRequest.shareKey` → **Queryable** (sonst findet die Einsatzleitung keine Anfragen).
3. *Schema → Deploy Schema Changes…* → in **Production** übernehmen. TestFlight und App Store nutzen die Produktionsumgebung – ohne diesen Schritt geht Teilen dort nicht.
4. Bei jeder späteren Schemaänderung (neue Felder) erneut deployen.

`aps-environment` steht auf `development`; beim Archivieren für App Store Connect setzt Xcode `production` selbst.

## Hochladen (Mac)

1. Repo holen, `ELRD.xcodeproj` öffnen.
2. Ziel „Any iOS Device (arm64)“ wählen.
3. **Product → Archive.**
4. Im Organizer: **Distribute App → App Store Connect → Upload**.
5. In App Store Connect → TestFlight:
   - Build abwarten (ca. 10–30 min).
   - Beim ersten Mal den Hinweis zur Verschlüsselung bestätigen (entfällt durch die Info.plist).
   - Testgruppe anlegen und Tester einladen.

Hinweis: Debug-Builds schalten alles frei (E76). TestFlight-Builds sind Release-Builds, dort gelten Testzeitraum und Abo. Für einen kostenlosen TestFlight-Test wäre ein eigener Schalter nötig (offene Frage E76).

## App-Store-Angaben „App-Datenschutz“

- **Datenerhebung:** „Keine Daten erfasst“. Alle Einsatzdaten bleiben auf dem Gerät. Kartenkacheln laden Apple, OpenStreetMap und OpenTopoMap direkt (siehe Datenschutzerklärung). Das ist keine Erhebung durch den Entwickler.
- **Tracking:** nein.
- **Datenschutzerklärung (URL):** Der Text liegt in der App (Einstellungen → Vereinbarungen). Für App Store Connect braucht es zusätzlich eine öffentliche Adresse, etwa eine Webseite oder ein GitHub-Pages-Dokument.

## Prüfliste für die Testrunde (Schritt 58)

Siehe `docs/GERAETETEST.md`.
