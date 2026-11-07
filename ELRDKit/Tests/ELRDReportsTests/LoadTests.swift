import Foundation
import Testing
import PDFKit
@testable import ELRDReports
@testable import ELRDDomain
@testable import ELRDPersistence
import ELRDStore
import ELRDSync

/// Belastungstest (Schritt 64): großer MANV mit 160 Patienten, 40 Einheiten und
/// vielen Tagebucheinträgen. Grenzen großzügig (CI-Rechner sind langsam) – sie
/// fangen grobe Ausreißer wie quadratische Laufzeiten ab.
@Suite("Belastung: großer MANV")
@MainActor
struct LoadTests {
    static let patientCount = 160
    static let unitCount = 40

    func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    struct Large {
        let store: MissionStore
        let repository: InMemoryRepository
        let session: SessionIdentity
        let clock: DeviceClock
        let seconds: Double
    }

    func makeLargeMission() throws -> Large {
        let repository = InMemoryRepository()
        let device = DeviceIdentity(deviceID: DeviceID(), numberPrefix: "A")!
        let clock = try DeviceClock(deviceID: device.deviceID, repository: repository)
        let session = SessionIdentity(userID: UserID(), displayName: "Last", device: device)
        let store = try MissionStore.create(
            NewMissionRequest(reason: "MANV Zugunglück", sectionNames: ["Bereitstellungsraum", "Patientenablage", "Behandlungsplatz"], initialSectionName: "Bereitstellungsraum"),
            repository: repository, session: session, clock: clock
        )
        let watch = ContinuousClock()
        let start = watch.now
        var units: [MissionUnit] = []
        for index in 0..<Self.unitCount {
            let type: UnitType = [.rtw, .rtw, .ktw, .nef][index % 4]
            units.append(try store.perform(AddTemporaryUnit(callsign: "RK TEST \(index)/1", type: type)))
        }
        let triages: [Sichtungskategorie] = [.sk1, .sk2, .sk2, .sk3, .sk3, .sk3]
        for index in 0..<Self.patientCount {
            let patient = try store.perform(AddPatient(triage: triages[index % triages.count]))
            try store.perform(EditPatient(patientID: patient.id) { $0.lastName = "Patient \(index)" })
            if index < Self.unitCount {
                try store.perform(AssignUnit(patientID: patient.id, unitID: units[index].id))
            }
            if index % 2 == 0 {
                try store.perform(AddJournalText("Lagemeldung \(index): weitere Verletzte gefunden"))
            }
        }
        return Large(store: store, repository: repository, session: session, clock: clock, seconds: seconds(watch.now - start))
    }

    @Test func commandsStayFastWithManyPatients() throws {
        let large = try makeLargeMission()
        let store = large.store
        let elapsed = large.seconds
        #expect(store.state.activePatients.count == Self.patientCount)
        // ca. 440 Befehle; je Befehl deutlich unter 50 ms.
        #expect(elapsed < 25, "Befehle zu langsam: \(elapsed) s")

        let watch = ContinuousClock()
        let reopenStart = watch.now
        let reopened = try MissionStore(missionID: store.missionID, repository: large.repository, session: large.session, clock: large.clock)
        #expect(reopened.state.activePatients.count == Self.patientCount)
        #expect(seconds(watch.now - reopenStart) < 5, "Öffnen zu langsam")

        let singleStart = watch.now
        try reopened.perform(AddPatient(triage: .sk1))
        #expect(seconds(watch.now - singleStart) < 1, "ein Befehl bei großem Einsatz zu langsam")
    }

    @Test func reportOfLargeMissionRenders() throws {
        let state = try makeLargeMission().store.state
        let input = ReportInput(mission: state.mission, patients: state.patients, units: state.units, sections: state.sections,
                                journal: state.journal, log: state.visibleLog, createdBy: "Last")
        let watch = ContinuousClock()
        let start = watch.now
        let blocks = ReportBuilder.blocks(for: ReportTemplateLibrary.full, input: input)
        let data = PDFReportRenderer.render(blocks, theme: .standard, info: ReportPageInfo(title: "Einsatzbericht", subtitle: "Last", author: "Last"))
        let elapsed = seconds(watch.now - start)
        let pdf = try #require(PDFDocument(data: data))
        #expect(pdf.pageCount > 5)
        #expect(elapsed < 20, "PDF zu langsam: \(elapsed) s")
    }

    @Test func syncImportOfLargeMissionIsFast() throws {
        let large = try makeLargeMission()
        let store = large.store
        let events = try large.repository.changeEvents(in: store.missionID)
        let other = InMemoryRepository()
        let otherClock = try DeviceClock(deviceID: DeviceID(), repository: other)
        let watch = ContinuousClock()
        let start = watch.now
        let result = try RemoteChangeImporter(repository: other, clock: otherClock).importEvents(events)
        #expect(result.newEvents == events.count)
        #expect(seconds(watch.now - start) < 15, "Übernahme zu langsam")
        #expect(try other.entities(Patient.self, in: store.missionID).count == Self.patientCount)
    }
}
