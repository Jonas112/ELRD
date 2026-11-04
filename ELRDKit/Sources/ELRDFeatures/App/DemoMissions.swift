import Foundation
import ELRDDomain
import ELRDAuth
import ELRDStore

/// Beispieleinsätze für Bildschirmfotos und Vorschauen (nur Demo-Umgebung).
///
/// Ein laufender Einsatz und mehrere beendete. Alle Orte sind erfunden,
/// Patienten tragen nur Nummern.
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
        for triage in [Sichtungskategorie.sk1, .sk1, .sk2, .sk2, .sk2, .sk3, .sk3, .sk3, .sk3, .ungesichtet] {
            try running.perform(AddPatient(triage: triage))
        }
        try running.perform(AddJournalText("Lage: 3 Pkw beteiligt, 1 Person eingeklemmt."))
    }
}
