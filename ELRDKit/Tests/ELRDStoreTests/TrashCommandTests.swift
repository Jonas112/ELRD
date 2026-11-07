import Foundation
import Testing
@testable import ELRDDomain
@testable import ELRDPersistence
@testable import ELRDStore

@Suite("Papierkorb: Gelöschtes wiederherstellen (Schritt 54)")
@MainActor
struct TrashCommandTests {
    @Test func deletedItemsAppearInTrashAndCanBeRestored() throws {
        let fixture = try StoreFixture()
        let store = try fixture.newMission()
        let patient = try store.perform(AddPatient(triage: .sk1))
        let entry = try store.perform(AddJournalText("Lagemeldung an ILS abgegeben"))
        let center = try #require(GeoCoordinate(latitude: 50.10, longitude: 10.18))
        let circle = try store.perform(AddMapObject(shape: .circle(center: center, radiusMeters: 100), title: "Gefahrenbereich"))
        #expect(store.state.trash.isEmpty)

        try store.perform(DeletePatient(patientID: patient.id))
        fixture.clock.advance(60)
        try store.perform(DeleteJournalEntry(entryID: entry.id))
        fixture.clock.advance(60)
        try store.perform(DeleteMapObject(objectID: circle.id))

        let trash = store.state.trash
        #expect(trash.map(\.kind) == [.mapObject, .journalEntry, .patient], "zuletzt gelöscht zuerst")
        #expect(trash.first?.title == "Gefahrenbereich")
        #expect(trash.last?.title == "Patient \(patient.number) · \(Sichtungskategorie.sk1.shortName)")
        #expect(trash[1].title.hasSuffix("Lagemeldung an ILS abgegeben"))

        for item in trash {
            try store.perform(RestoreDeleted(item))
        }
        #expect(store.state.trash.isEmpty)
        #expect(store.state.activePatients.contains { $0.id == patient.id })
        #expect(store.state.journal.active.contains { $0.id == entry.id })
        #expect(store.state.mapObjects.active.contains { $0.id == circle.id })
        #expect(store.state.visibleLog.last?.message == "Patient \(patient.number) wiederhergestellt")

        // Ein nicht gelöschter Eintrag lässt sich nicht „wiederherstellen“.
        #expect(throws: CommandError.notFound(.patient)) {
            try store.perform(RestoreDeleted(kind: .patient, entityID: patient.id.rawValue))
        }
        // Wiederhergestellt lässt er sich normal weiter bearbeiten.
        try store.perform(SetTriage(patientID: patient.id, triage: .sk2))
        #expect(store.state.activePatients.first { $0.id == patient.id }?.triage == .sk2)
    }

    @Test func restoreWritesRestoreEventForSync() throws {
        let fixture = try StoreFixture()
        let store = try fixture.newMission()
        let patient = try store.perform(AddPatient(triage: .sk3))
        try store.perform(DeletePatient(patientID: patient.id))
        try store.perform(RestoreDeleted(kind: .patient, entityID: patient.id.rawValue))
        let operations = try store.changeEvents()
            .filter { $0.entityID == patient.id.rawValue }
            .map(\.operation)
        #expect(operations == [.insert, .delete, .restore])
    }

    @Test func deletedMissionCanBeRestored() throws {
        let fixture = try StoreFixture()
        let store = try fixture.newMission()
        try store.perform(DeleteMission())
        #expect(try MissionOverview.load(from: fixture.repository).isEmpty)
        #expect(try MissionOverview.loadDeleted(from: fixture.repository).map(\.id) == [store.missionID])

        let reopened = try fixture.open(store.missionID, device: fixture.deviceA)
        try reopened.perform(RestoreMission())
        #expect(try MissionOverview.load(from: fixture.repository).map(\.id) == [store.missionID])
        #expect(try MissionOverview.loadDeleted(from: fixture.repository).isEmpty)
        #expect(reopened.state.visibleLog.last?.message.hasSuffix("wiederhergestellt") == true)
    }

    @Test func automaticJournalEntriesNeverShowInTrash() throws {
        let fixture = try StoreFixture()
        let store = try fixture.newMission()
        try store.perform(CloseMission())
        try store.perform(ReopenMission())
        #expect(store.state.trash.isEmpty)
        #expect(TrashItem.Kind.allCases.allSatisfy { !$0.displayName.isEmpty && !$0.systemImage.isEmpty })
    }
}

@Suite("Vorschaubild in der Einsatzliste")
@MainActor
struct MissionThumbnailTests {
    @Test func firstPhotoBecomesThumbnail() throws {
        let fixture = try StoreFixture()
        let store = try fixture.newMission()
        #expect(try MissionOverview.load(from: fixture.repository).first?.thumbnail == nil)
        let photo = FileAttachment(kind: .photo, byteCount: 3, sha256: "abc", createdAt: fixture.clock.now)
        try store.perform(AddJournalMedia(attachments: [photo], text: "Einsatzstelle"))
        #expect(try MissionOverview.load(from: fixture.repository).first?.thumbnail == photo)
    }
}
