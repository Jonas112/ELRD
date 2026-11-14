import Foundation
import UIKit
import ELRDDomain
import ELRDAuth
import ELRDPersistence
import ELRDStore

/// Beispieleinsätze für Bildschirmfotos und Vorschauen (nur Demo-Umgebung).
///
/// Ein laufender Einsatz und mehrere beendete. Alle Orte und Personen sind erfunden.
@MainActor
enum DemoMissions {
    /// Uhr, die beim Anlegen „zurückgedreht“ werden kann.
    private final class TimeBox {
        var date: Date
        init(_ date: Date) { self.date = date }
    }

    private struct Finished {
        let reason: String
        let type: MissionType?
        let location: String
        let daysAgo: Double
        let hours: Double
        let patients: [Sichtungskategorie]
    }

    private static let finished: [Finished] = [
        Finished(reason: "Gefahrgut Lkw", type: .gefahrgut, location: "A 71, Parkplatz Beispielwald", daysAgo: 61, hours: 4.2, patients: [.sk2, .sk3]),
        Finished(reason: "BMA Pflegeheim", type: .bma, location: "Musterstadt, Lindenweg", daysAgo: 44, hours: 0.8, patients: []),
        Finished(reason: "VU Linienbus", type: .verkehrsunfall, location: "St 2290, Ortseingang Beispielheim", daysAgo: 33, hours: 1.8,
                 patients: [.sk1, .sk2, .sk2, .sk3, .sk3, .sk3, .sk3, .sk3, .unverletzt]),
        Finished(reason: "Mehrere Erkrankte – Schulfest", type: .mehrfachErkrankte, location: "Musterstadt, Festplatz", daysAgo: 16, hours: 2.3,
                 patients: [.sk2, .sk2, .sk3, .sk3, .sk3, .sk3, .sk3, .sk3, .unverletzt, .unverletzt, .unverletzt]),
        Finished(reason: "Brand Wohnhaus", type: .brand, location: "Musterdorf, Hauptstraße", daysAgo: 7, hours: 3.1, patients: [.sk1, .sk3, .sk3, .unverletzt]),
    ]

    static func seed(in environment: AppEnvironment, user: UserAccount, now: Date = Date()) throws {
        let session = SessionIdentity(userID: user.id, displayName: user.displayName, device: environment.device)
        let time = TimeBox(now)

        func create(_ request: NewMissionRequest, startedAt: Date) throws -> MissionStore {
            time.date = startedAt
            return try MissionStore.create(
                request,
                repository: environment.repository,
                session: session,
                clock: environment.deviceClock,
                entitlements: environment.entitlements,
                now: { time.date }
            )
        }

        for mission in finished {
            let start = now.addingTimeInterval(-mission.daysAgo * 86_400)
            let store = try create(NewMissionRequest(reason: mission.reason, type: mission.type, location: mission.location), startedAt: start)
            time.date = start.addingTimeInterval(600)
            for triage in mission.patients { try store.perform(AddPatient(triage: triage)) }
            time.date = start.addingTimeInterval(mission.hours * 3_600)
            try store.perform(CloseMission())
        }

        let start = now.addingTimeInterval(-42 * 60)
        let running = try create(
            NewMissionRequest(
                reason: "VU mit mehreren Pkw",
                type: .verkehrsunfall,
                location: "B 19, Höhe Ausfahrt Musterstadt",
                alarmstichwort: .rd3
            ),
            startedAt: start
        )
        time.date = start.addingTimeInterval(8 * 60)
        var added: [Patient] = []
        for triage in [Sichtungskategorie.sk1, .sk1, .sk2, .sk2, .sk2, .sk3, .sk3, .sk3, .sk3, .ungesichtet] {
            added.append(try running.perform(AddPatient(triage: triage)))
        }
        // Einige Personendaten, wie sie im Einsatz nach und nach dazukommen.
        let calendar = Calendar(identifier: .gregorian)
        try running.perform(EditPatient(patientID: added[0].id) {
            $0.firstName = "Thomas"
            $0.lastName = "Mustermann"
            $0.dispatchPatientNumber = "2614-0471-01"
            $0.gender = .maennlich
            $0.birthDate = calendar.date(from: DateComponents(year: 1981, month: 3, day: 14, hour: 12))
            $0.identifyingFeatures = "Fahrer Pkw rot, eingeklemmt, blaue Arbeitsjacke"
            $0.notes = "2 Zugänge, 500 ml VEL. GCS 13."
            $0.circulation = .stabil
            $0.rmiCode = 212
            $0.treatmentPriority = .sofortigeIntervention
            $0.abcd = ABCDStatus(airway: 2, breathing: 2, circulation: 2)
            $0.traumaRoom = .a
        })
        try running.perform(AddInjury(patientID: added[0].id, injury: Injury(diagnosis: "Unterschenkel#", region: .unterschenkel, side: .rechts)))
        try running.perform(AddInjury(patientID: added[0].id, injury: Injury(diagnosis: "stumpfes Thoraxtrauma", region: .thorax)))
        try running.perform(AddInjury(patientID: added[2].id, injury: Injury(diagnosis: "Oberarm#", region: .arm, side: .links)))
        try running.perform(EditPatient(patientID: added[1].id) {
            $0.gender = .weiblich
            $0.estimatedAge = 30
            $0.identifyingFeatures = "Beifahrerin Pkw rot, rote Daunenjacke"
        })
        try running.perform(EditPatient(patientID: added[2].id) {
            $0.firstName = "Anna-Katharina"
            $0.lastName = "Beispiel-Hoffmann"
            $0.dispatchPatientNumber = "2614-0471-02"
            $0.gender = .weiblich
            $0.estimatedAge = 61
            $0.identifyingFeatures = "Fahrerin Pkw blau"
        })
        try running.perform(EditPatient(patientID: added[9].id) {
            $0.identifyingFeatures = "im Graben, rechte Fahrbahnseite"
        })
        // Einsatzort nahe Schweinfurt, damit Kliniken nach Entfernung sortiert werden.
        try running.perform(EditMission { $0.coordinate = GeoCoordinate(latitude: 50.10, longitude: 10.18) })

        // Versorgungsstand: Einheiten zugeordnet, Kliniken angefragt, ein Transport.
        let hospitals = (try? environment.repository.document(MasterDataSet.self, key: .masterData))?.hospitals ?? []
        let leo = hospitals.first { $0.name == "LEO Schweinfurt" }?.snapshot
        let josef = hospitals.first { $0.name == "KHS St. Josef Schweinfurt" }?.snapshot
        let rtws = running.state.activeUnits.filter { $0.type == .rtw }
        if rtws.count >= 2 {
            try running.perform(AssignUnit(patientID: added[2].id, unitID: rtws[0].id))
            try running.perform(AssignUnit(patientID: added[3].id, unitID: rtws[1].id))
        }
        if let josef {
            try running.perform(SetDestination(patientID: added[2].id, hospital: josef))
            try running.perform(SetRegistration(patientID: added[2].id, state: .angemeldet))
        }
        if let leo {
            try running.perform(SetDestination(patientID: added[1].id, hospital: leo))
            try running.perform(SetRegistration(patientID: added[1].id, state: .angefragt))
            try running.perform(SetDestination(patientID: added[3].id, hospital: leo))
            try running.perform(SetRegistration(patientID: added[3].id, state: .angemeldet))
            // A-1: Schockraum angefragt (zeigt die Statusfarben in den Bildschirmfotos).
            try running.perform(SetDestination(patientID: added[0].id, hospital: leo))
            try running.perform(SetRegistration(patientID: added[0].id, state: .angefragt))
        }
        time.date = start.addingTimeInterval(30 * 60)
        if rtws.count >= 2 { try running.perform(StartTransport(patientID: added[3].id)) }
        try running.perform(AddJournalText("Erstmeldung an ILS abgegeben", occurredAt: start.addingTimeInterval(4 * 60)))
        try running.perform(AddJournalText("Nachalarmierung angefordert: 2 RTW, 1 KTW", occurredAt: start.addingTimeInterval(12 * 60)))
        try running.perform(AddJournalText("Lage: 3 Pkw beteiligt, 1 Person eingeklemmt."))
        _ = try running.perform(SendMessage("Landeplatz RTH auf der Wiese nördlich freihalten.", kind: .warning))

        // Abschnitte: Bereitstellungsraum wird Initialabschnitt; eine Einheit bleibt ohne Abschnitt.
        let staging = try running.perform(AddSection(name: "Bereitstellungsraum"))
        let scene = try running.perform(AddSection(name: "Einsatzstelle"))
        let casualties = try running.perform(AddSection(name: "Patientenablage"))
        // Auf der Karte: Bereitstellungsraum und Einsatzstelle; die Patientenablage noch nicht.
        try running.perform(SetSectionCoordinate(sectionID: staging.id, coordinate: GeoCoordinate(latitude: 50.1032, longitude: 10.1752)))
        try running.perform(SetSectionCoordinate(sectionID: scene.id, coordinate: GeoCoordinate(latitude: 50.1001, longitude: 10.1806)))
        // Markierungen: Gefahrenbereich um die Unfallstelle, Landeplatz für den RTH.
        if let hazardCenter = GeoCoordinate(latitude: 50.1000, longitude: 10.1800) {
            _ = try running.perform(AddMapObject(shape: .circle(center: hazardCenter, radiusMeters: 50), title: "Gefahrenbereich"))
        }
        if let padCenter = GeoCoordinate(latitude: 50.1022, longitude: 10.1830),
           let pad = GeoBounds.around(padCenter, widthMeters: 50, heightMeters: 25) {
            _ = try running.perform(AddMapObject(shape: .rectangle(bounds: pad), title: "Landeplatz RTH", color: RGBColor(hex: 0x1976D2)))
        }
        // Freihand: Anfahrtsweg als Pfeil von der B 19 zur Einsatzstelle.
        if let arrowCenter = GeoCoordinate(latitude: 50.1012, longitude: 10.1785),
           let arrowBounds = GeoBounds.around(arrowCenter, widthMeters: 160, heightMeters: 90),
           let png = Self.demoArrowPNG() {
            let file = try environment.attachments.save(png, kind: .drawing, createdAt: time.date, pixelWidth: 640, pixelHeight: 360)
            _ = try running.perform(AddMapObject(shape: .drawing(bounds: arrowBounds, image: file), title: "Anfahrt"))
        }
        // Kartenausschnitt im Tagebuch (Beispielbild statt echter Karte).
        if let jpeg = Self.demoSnapshotJPEG() {
            let file = try environment.attachments.save(jpeg, kind: .photo, createdAt: time.date, pixelWidth: 1200, pixelHeight: 800)
            _ = try running.perform(AddMapSnapshot(image: file))
        }
        // Schritt 111: Foto mit Aufnahmeort (erscheint als Marker auf der Karte).
        if let jpeg = Self.demoSnapshotJPEG(), let place = GeoCoordinate(latitude: 50.0978, longitude: 10.1835) {
            let file = try environment.attachments.save(jpeg, kind: .photo, createdAt: time.date, pixelWidth: 1200, pixelHeight: 800, coordinate: place)
            _ = try running.perform(AddJournalMedia(attachments: [file], text: "Unfallstelle von Süden"))
        }
        // Schritte 114–115: taktische Zeichen, Fläche und Pfeil.
        let signs: [(String, Double, Double)] = [("elrd", 50.1036, 10.1745), ("rtw", 50.1003, 10.1815), ("pa", 50.0992, 10.1790), ("lp", 50.1027, 10.1838)]
        for (presetID, latitude, longitude) in signs {
            guard let preset = TacticalSignPreset.preset(presetID), let place = GeoCoordinate(latitude: latitude, longitude: longitude) else { continue }
            _ = try running.perform(AddMapObject.sign(preset.sign, at: place))
        }
        let zone = MapPath(kind: .polygon, points: [
            GeoCoordinate(latitude: 50.1016, longitude: 10.1760), GeoCoordinate(latitude: 50.1021, longitude: 10.1772),
            GeoCoordinate(latitude: 50.1012, longitude: 10.1779), GeoCoordinate(latitude: 50.1008, longitude: 10.1766),
        ].compactMap { $0 })
        if let command = AddMapObject.withPath(zone, title: "Sperrzone", color: RGBColor(hex: 0xF57C00)) { _ = try running.perform(command) }
        let route = MapPath(kind: .arrow, points: [
            GeoCoordinate(latitude: 50.1040, longitude: 10.1750), GeoCoordinate(latitude: 50.1030, longitude: 10.1770),
            GeoCoordinate(latitude: 50.1010, longitude: 10.1800),
        ].compactMap { $0 })
        if let command = AddMapObject.withPath(route, title: "Zufahrt", color: RGBColor(hex: 0x1976D2)) { _ = try running.perform(command) }
        // Schritt 123: Suchgebiete werden automatisch durchnummeriert.
        let searchAreas: [[(Double, Double)]] = [
            [(50.1050, 10.1700), (50.1062, 10.1712), (50.1056, 10.1732), (50.1044, 10.1724)],
            [(50.0992, 10.1790), (50.1000, 10.1808), (50.0990, 10.1820), (50.0982, 10.1802)],
        ]
        for corners in searchAreas {
            let area = MapPath(kind: .polygon, points: corners.compactMap { GeoCoordinate(latitude: $0.0, longitude: $0.1) })
            if let command = AddMapObject.withPath(area, color: RGBColor(hex: 0x388E3C)) { _ = try running.perform(command) }
        }
        // Schritt 109: automatisches Lagebild (Text; das Kartenbild braucht MapKit).
        _ = try running.perform(AddSituationSnapshot(text: SituationSnapshot.text(running.state, openItemCount: 3, now: time.date)))
        if rtws.count >= 2 { try running.perform(MoveUnit(unitID: rtws[0].id, to: scene.id)) }
        if let nef = running.state.activeUnits.first(where: { $0.type == .nef }) {
            try running.perform(MoveUnit(unitID: nef.id, to: staging.id))
        }
        // Einheiten aus den Stammdaten (Region Schweinfurt) und eine temporäre.
        let masterUnits = (try? environment.repository.document(MasterDataSet.self, key: .masterData))?.units ?? []
        let picked = ["RK SWFT 71/1", "RK SWFT 76/1"].compactMap { name in masterUnits.first { $0.callsign == name } }
        _ = try running.perform(AddMasterUnits(picked, sectionID: staging.id))
        _ = try running.perform(AddTemporaryUnit(callsign: "HvO Musterdorf", type: .sonstiges, sectionID: scene.id))
        // Nachalarmierter KTW, Fahrzeug noch unbekannt.
        _ = try running.perform(AddPlaceholder(type: .ktw, sectionID: staging.id))
        for patient in [added[4], added[5]] {
            try running.perform(EditPatient(patientID: patient.id) { $0.sectionID = casualties.id })
        }

        // Schritte 67–76: Führung, Kontingente, Anhängekarte, Checkliste, Lagemeldung.
        try running.perform(SetLeadershipPosition(LeadershipPosition(role: .einsatzleiter, name: user.displayName, callsign: "ELRD 1", radioChannel: "TMO 312")))
        try running.perform(SetLeadershipPosition(LeadershipPosition(role: .lna, name: "Dr. Weber", callsign: "LNA SW", radioChannel: "TMO 312")))
        try running.perform(SetLeadershipPosition(LeadershipPosition(role: .orgl, name: "M. Krause", callsign: "OrgL SW", radioChannel: "TMO 312")))
        try running.perform(SetSectionLeader(sectionID: casualties.id, name: "S. Lang", callsign: "RK SWF 10/1", radioChannel: "TMO 313",
                                             phone: "0170 0000013", task: "Patientenablage betreiben, Sichtung nachführen"))
        try running.perform(SetSectionLeader(sectionID: staging.id, name: "T. Roth", callsign: "RK SWF 11/1", radioChannel: "TMO 314",
                                             phone: "0170 0000014", task: "Bereitstellungsraum führen, Kräfte zuweisen"))
        // Schritt 126: Kommunikationsplan nach DV 800 (fiktive Nummern).
        try running.perform(SetLeadershipPosition(LeadershipPosition(role: .fuehrungsassistenz, name: "J. Becker", callsign: "ELRD 1/1",
                                                                     radioChannel: "TMO 312", phone: "0170 0000011")))
        try running.perform(SetCommunicationContacts([
            CommunicationContact(name: "Integrierte Leitstelle (ILS)", callsign: "Leitstelle Schweinfurt", channel: "TMO 312", phone: "09721 0000000"),
            CommunicationContact(name: "Feuerwehr – Einsatzleitung", callsign: "Florian SW 1/10", channel: "TMO 312", isNeighbouringForce: true),
            CommunicationContact(name: "Polizei – Einsatzleitung", phone: "09721 0000001", isNeighbouringForce: true),
        ]))
        if let leo {
            try running.perform(SetHospitalQuota(HospitalQuota(masterHospitalID: leo.masterHospitalID, hospitalName: leo.name, sk1: 1, sk2: 2, sk3: 4)))
        }
        if let josef {
            try running.perform(SetHospitalQuota(HospitalQuota(masterHospitalID: josef.masterHospitalID, hospitalName: josef.name, sk1: 1, sk2: 1)))
        }
        try running.perform(SetPatientTag(patientID: added[0].id, tagNumber: "PAK-0731"))
        for item in ChecklistTemplate.standard.items.prefix(4) {
            try running.perform(CheckChecklistItem(item))
        }
        // Schritt 143: laufender Einsatz stammt aus FE2, dort gibt es schon einen neuen Stand.
        if environment.demoScreen == .alamosUpdate || environment.demoScreen == .alamosUpdateReview {
            try running.perform(LinkExternalAlarm(alarm: AlamosDemo.importedBus(now: now)))
        }
        try running.perform(AddSituationReport(
            text: SituationReport.text(for: running.state, now: now),
            situationNote: "3 Pkw beteiligt, 1 Person eingeklemmt, Patientenablage eingerichtet",
            hazards: "auslaufender Kraftstoff, fließender Verkehr in Gegenrichtung"
        ))
    }

    /// Rot gezeichneter Pfeil (transparentes PNG) für die Beispielzeichnung.
    static func demoArrowPNG() -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 360), format: format)
        let image = renderer.image { context in
            let path = UIBezierPath()
            path.move(to: CGPoint(x: 40, y: 60))
            path.addCurve(to: CGPoint(x: 560, y: 290), controlPoint1: CGPoint(x: 260, y: 40), controlPoint2: CGPoint(x: 360, y: 300))
            path.move(to: CGPoint(x: 560, y: 290))
            path.addLine(to: CGPoint(x: 500, y: 220))
            path.move(to: CGPoint(x: 560, y: 290))
            path.addLine(to: CGPoint(x: 470, y: 310))
            UIColor(MapObject.defaultColor).setStroke()
            path.lineWidth = 18
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()
            _ = context
        }
        return image.pngData()
    }

    /// Schlichtes Beispiel-Logo (rotes Kreuz auf weißem Grund).
    static func demoBannerPNG() -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 120), format: format)
        let image = renderer.image { _ in
            UIColor.white.setFill()
            UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: 120, height: 120), cornerRadius: 24).fill()
            UIColor(red: 0.83, green: 0.18, blue: 0.18, alpha: 1).setFill()
            UIBezierPath(rect: CGRect(x: 45, y: 15, width: 30, height: 90)).fill()
            UIBezierPath(rect: CGRect(x: 15, y: 45, width: 90, height: 30)).fill()
        }
        return image.pngData()
    }

    /// Einfaches Bild im Stil einer Lagekarte (Grünfläche, Straße, roter Kreis).
    static func demoSnapshotJPEG() -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: 1200, height: 800)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(red: 0.80, green: 0.90, blue: 0.74, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let road = UIBezierPath()
            road.move(to: CGPoint(x: 520, y: 0))
            road.addCurve(to: CGPoint(x: 380, y: 800), controlPoint1: CGPoint(x: 420, y: 300), controlPoint2: CGPoint(x: 460, y: 500))
            UIColor.white.setStroke()
            road.lineWidth = 34
            road.stroke()
            let hazard = UIBezierPath(ovalIn: CGRect(x: 520, y: 380, width: 180, height: 180))
            UIColor(MapObject.defaultColor).withAlphaComponent(0.25).setFill()
            hazard.fill()
            UIColor(MapObject.defaultColor).setStroke()
            hazard.lineWidth = 6
            hazard.stroke()
        }
        return image.jpegData(compressionQuality: 0.8)
    }
}
