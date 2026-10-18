import Foundation
import Testing
@testable import ELRDDomain

private enum Sample {
    static let missionID = MissionID()
    static let checksum = String(repeating: "ab", count: 32)

    static func meta(_ offset: TimeInterval = 0) -> EntityMetadata {
        .new(by: Fixture.author, at: Fixture.start.addingTimeInterval(offset))
    }

    static func attachment(_ kind: AttachmentKind) -> FileAttachment {
        FileAttachment(kind: kind, byteCount: 1024, sha256: checksum.uppercased(), createdAt: Fixture.start)
    }

    static func entry(number: SerialNumber, minutes: Double, text: String = "Lage", attachments: [FileAttachment] = []) -> JournalEntry {
        JournalEntry(
            missionID: missionID,
            metadata: meta(),
            number: number,
            occurredAt: Fixture.start.addingTimeInterval(minutes * 60),
            text: text,
            attachments: attachments
        )
    }
}

@Suite("Anhänge")
struct AttachmentTests {
    @Test func fileNameAndChecksum() {
        let photo = Sample.attachment(.photo)
        #expect(photo.fileName.hasSuffix(".jpg"))
        #expect(photo.fileName.hasPrefix(photo.id.rawValue.uuidString.lowercased()))
        #expect(photo.sha256 == Sample.checksum, "Prüfsumme wird klein geschrieben")
        #expect(photo.hasValidChecksum)
        #expect(!FileAttachment(kind: .audio, byteCount: -5, sha256: "xyz", createdAt: Fixture.start).hasValidChecksum)
        #expect(FileAttachment(kind: .audio, byteCount: -5, sha256: "", createdAt: Fixture.start).byteCount == 0)
    }

    @Test func legacyRawValues() {
        #expect(AttachmentKind.audio.rawValue == 1)
        #expect(AttachmentKind.photo.rawValue == 2)
        #expect(AttachmentKind.video.rawValue == 3)
    }
}

@Suite("Einsatztagebuch")
struct JournalEntryTests {
    @Test func kindFollowsFirstAttachment() {
        #expect(Sample.entry(number: 1, minutes: 0).kind == .text)
        #expect(Sample.entry(number: 2, minutes: 0, attachments: [Sample.attachment(.audio)]).kind == .audio)
        #expect(Sample.entry(number: 3, minutes: 0, attachments: [Sample.attachment(.drawing)]).kind == .photo)
    }

    @Test func attachmentsAreUnique() {
        let photo = Sample.attachment(.photo)
        var entry = Sample.entry(number: 1, minutes: 0, attachments: [photo, photo])
        #expect(entry.attachments.count == 1)
        entry.removeAttachment(photo.id)
        #expect(entry.attachments.isEmpty)
    }

    @Test func emptyEntries() {
        #expect(Sample.entry(number: 1, minutes: 0, text: "  ").isEmpty)
        #expect(!Sample.entry(number: 1, minutes: 0, text: "", attachments: [Sample.attachment(.photo)]).isEmpty)
    }

    @Test func numberingCountsDeletedEntries() {
        var deleted = Sample.entry(number: 4, minutes: 0)
        deleted.metadata.markDeleted(by: Fixture.author, at: Fixture.start)
        #expect(JournalEntry.nextNumber(prefix: "", existing: [Sample.entry(number: 2, minutes: 0), deleted]) == 5)
        #expect(JournalEntry.nextNumber(prefix: "B", existing: []).description == "B-1")
    }

    @Test func chronologicalOrder() {
        let entries = [
            Sample.entry(number: 3, minutes: 10),
            Sample.entry(number: 1, minutes: 5),
            Sample.entry(number: 2, minutes: 5),
        ]
        #expect(JournalEntry.chronological(entries).map(\.number) == [1, 2, 3])
    }

    @Test func thumbnailPrefersMarkedEntry() {
        let firstPhoto = Sample.attachment(.photo)
        let markedPhoto = Sample.attachment(.photo)
        var marked = Sample.entry(number: 2, minutes: 20, attachments: [markedPhoto])
        let entries = [Sample.entry(number: 1, minutes: 10, attachments: [firstPhoto]), marked]
        #expect(JournalEntry.thumbnail(in: entries)?.id == firstPhoto.id)
        marked.isMissionThumbnail = true
        #expect(JournalEntry.thumbnail(in: [entries[0], marked])?.id == markedPhoto.id)
        #expect(JournalEntry.thumbnail(in: [Sample.entry(number: 1, minutes: 0)]) == nil)
    }
}

@Suite("Nachrichten")
struct MissionMessageTests {
    func message(minutes: Double) -> MissionMessage {
        MissionMessage(
            missionID: Sample.missionID,
            metadata: Sample.meta(),
            sentAt: Fixture.start.addingTimeInterval(minutes * 60),
            senderName: "ELRD",
            text: "Hinweis \(Int(minutes))",
            kind: .system
        )
    }

    @Test func acknowledgeOnlyOnce() {
        var msg = message(minutes: 0)
        let first = UserID()
        msg.acknowledge(by: first, at: Fixture.start)
        msg.acknowledge(by: UserID(), at: Fixture.start.addingTimeInterval(60))
        #expect(msg.isAcknowledged)
        #expect(msg.acknowledgedBy == first)
        #expect(msg.acknowledgedAt == Fixture.start)
    }

    @Test func badgeCountAndOrder() {
        var read = message(minutes: 1)
        read.acknowledge(by: nil, at: Fixture.start)
        let messages = [message(minutes: 0), read, message(minutes: 2)]
        #expect(MissionMessage.unacknowledgedCount(in: messages) == 2)
        #expect(MissionMessage.newestFirst(messages).map(\.text) == ["Hinweis 2", "Hinweis 1", "Hinweis 0"])
    }
}

@Suite("Einsatzprotokoll")
struct MissionLogTests {
    @Test func visibilityByLevel() {
        func entry(_ minutes: Double, _ level: LogLevel) -> MissionLogEntry {
            MissionLogEntry(
                missionID: Sample.missionID,
                metadata: Sample.meta(),
                timestamp: Fixture.start.addingTimeInterval(minutes * 60),
                category: .patient,
                level: level,
                message: "Patient \(Int(minutes))",
                subject: .patient(PatientID())
            )
        }
        let entries = [entry(3, .user), entry(1, .developer), entry(2, .admin), entry(0, .user)]
        #expect(MissionLogEntry.visible(entries).map(\.message) == ["Patient 0", "Patient 3"])
        #expect(MissionLogEntry.visible(entries, maximumLevel: .admin).count == 3)
        #expect(entries[0].authorID == Fixture.author)
        #expect(LogLevel.allCases.map(\.rawValue) == [1, 2, 3])
    }
}

@Suite("Lagekarte")
struct MapObjectTests {
    let center = GeoCoordinate(latitude: 50.3, longitude: 10.2)!

    @Test func boundsValidation() {
        #expect(GeoBounds(north: 50.4, south: 50.3, east: 10.3, west: 10.2) != nil)
        #expect(GeoBounds(north: 50.3, south: 50.4, east: 10.3, west: 10.2) == nil)
        #expect(GeoBounds(north: 95, south: 50, east: 10.3, west: 10.2) == nil)

        let other = GeoCoordinate(latitude: 50.1, longitude: 10.6)!
        let bounds = GeoBounds(enclosing: center, other)
        #expect(bounds.north == 50.3 && bounds.south == 50.1)
        #expect(bounds.contains(GeoCoordinate(latitude: 50.2, longitude: 10.4)!))
        #expect(!bounds.contains(GeoCoordinate(latitude: 50.5, longitude: 10.4)!))
        #expect(abs(bounds.center.latitude - 50.2) < 0.000_001)
    }

    @Test func circleRadiusMustBeSensible() {
        let valid = MapObject(missionID: Sample.missionID, metadata: Sample.meta(), shape: .circle(center: center, radiusMeters: 250))
        #expect(valid?.displayName == "Kreis, Radius 250 m")
        #expect(MapObject(missionID: Sample.missionID, metadata: Sample.meta(), shape: .circle(center: center, radiusMeters: 0)) == nil)
        #expect(MapObject(missionID: Sample.missionID, metadata: Sample.meta(), shape: .circle(center: center, radiusMeters: .infinity)) == nil)
    }

    @Test func drawingNeedsDrawingAttachment() {
        let bounds = GeoBounds(enclosing: center, GeoCoordinate(latitude: 50.31, longitude: 10.21)!)
        #expect(MapShape.drawing(bounds: bounds, image: Sample.attachment(.drawing)).isValid)
        #expect(!MapShape.drawing(bounds: bounds, image: Sample.attachment(.audio)).isValid)
    }

    @Test func invalidShapeChangeIsRejected() {
        var object = MapObject(
            missionID: Sample.missionID,
            metadata: Sample.meta(),
            title: " Gefahrenbereich ",
            shape: .circle(center: center, radiusMeters: 100)
        )!
        #expect(object.displayName == "Gefahrenbereich")
        let rejected = object.setShape(.circle(center: center, radiusMeters: -1))
        #expect(!rejected)
        #expect(object.shape == .circle(center: center, radiusMeters: 100))
        let accepted = object.setShape(.circle(center: center, radiusMeters: 500))
        #expect(accepted)
        #expect(object.shape.center == center)
    }

    @Test func shapeRoundTripsThroughJSON() throws {
        let bounds = GeoBounds(enclosing: center, GeoCoordinate(latitude: 50.31, longitude: 10.21)!)
        let shapes: [MapShape] = [
            .circle(center: center, radiusMeters: 42),
            .rectangle(bounds: bounds),
            .drawing(bounds: bounds, image: Sample.attachment(.drawing)),
        ]
        let decoded = try JSONDecoder().decode([MapShape].self, from: JSONEncoder().encode(shapes))
        #expect(decoded == shapes)
    }
}
