import Foundation
import ELRDDomain
import ELRDPersistence

/// Beispieldaten für SwiftUI-Vorschauen und Tests (nur im Arbeitsspeicher).
///
/// Enthält bewusst keine Personennamen – Beispielpatienten tragen nur Nummern.
@MainActor
public enum PreviewData {
    public static let session = SessionIdentity(
        userID: UserID(),
        displayName: "Einsatzleiter Beispiel",
        device: DeviceIdentity(deviceID: DeviceID(), numberPrefix: DeviceIdentity.defaultPrefix)!
    )

    /// Ein laufender Einsatz mit Abschnitten, Platzhaltern, Patienten und Tagebuch.
    public static func makeStore(now: Date = Date()) throws -> MissionStore {
        let repository = InMemoryRepository()
        let clock = try DeviceClock(deviceID: session.device.deviceID, repository: repository)
        let store = try MissionStore.create(
            NewMissionRequest(
                reason: "VU mit mehreren Pkw",
                type: .verkehrsunfall,
                location: "B 19, Höhe Ausfahrt Musterstadt",
                sectionNames: ["Bereitstellungsraum", "Patientenablage", "Behandlungsplatz"],
                initialSectionName: "Bereitstellungsraum"
            ),
            repository: repository,
            session: session,
            clock: clock,
            now: { now }
        )
        try store.perform(AddAlarmstichwort(.rd3))
        for triage in [Sichtungskategorie.sk1, .sk2, .sk2, .sk3, .sk3, .sk3, .ungesichtet] {
            try store.perform(AddPatient(triage: triage))
        }
        try store.perform(AddJournalText("Lage: 3 Pkw beteiligt, 1 Person eingeklemmt."))
        return store
    }
}
