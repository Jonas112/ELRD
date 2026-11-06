import Foundation
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
        }
        time.date = start.addingTimeInterval(30 * 60)
        if rtws.count >= 2 { try running.perform(StartTransport(patientID: added[3].id)) }
        try running.perform(AddJournalText("Lage: 3 Pkw beteiligt, 1 Person eingeklemmt."))

        // Abschnitte: Bereitstellungsraum wird Initialabschnitt; eine Einheit bleibt ohne Abschnitt.
        let staging = try running.perform(AddSection(name: "Bereitstellungsraum"))
        let scene = try running.perform(AddSection(name: "Einsatzstelle"))
        let casualties = try running.perform(AddSection(name: "Patientenablage"))
        // Auf der Karte: Bereitstellungsraum und Einsatzstelle; die Patientenablage noch nicht.
        try running.perform(SetSectionCoordinate(sectionID: staging.id, coordinate: GeoCoordinate(latitude: 50.1032, longitude: 10.1752)))
        try running.perform(SetSectionCoordinate(sectionID: scene.id, coordinate: GeoCoordinate(latitude: 50.1001, longitude: 10.1806)))
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
    }
}
