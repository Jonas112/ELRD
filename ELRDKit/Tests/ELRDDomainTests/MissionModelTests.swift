import Foundation
import Testing
@testable import ELRDDomain

/// Feste Zeitpunkte und Kalender, damit Tests unabhängig von Gerät und Zeitzone sind.
enum Fixture {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }()

    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    static let author = UserID()
    static let start = date(2026, 10, 18, 10, 0)

    static func mission(
        yearNumber: Int = 1,
        startedAt: Date = start,
        reason: String = "",
        type: MissionType? = nil
    ) -> Mission {
        Mission(
            metadata: .new(by: author, at: startedAt),
            yearNumber: yearNumber,
            reason: reason,
            type: type,
            startedAt: startedAt
        )
    }
}

@Suite("Kennungen und Metadaten")
struct IdentityTests {
    @Test func entityIDEncodesAsPlainUUIDString() throws {
        let uuid = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
        let data = try JSONEncoder().encode(MissionID(uuid))
        #expect(String(decoding: data, as: UTF8.self) == "\"6F9619FF-8B86-D011-B42D-00C04FC964FF\"")
        #expect(try JSONDecoder().decode(MissionID.self, from: data) == MissionID(uuid))
        #expect(MissionID(uuidString: "kein-uuid") == nil)
    }

    @Test func metadataTracksChangesAndSoftDelete() {
        let creator = UserID()
        let editor = UserID()
        var meta = EntityMetadata.new(by: creator, at: Fixture.start)
        #expect(meta.version == 1)
        #expect(meta.updatedBy == creator)

        meta.recordChange(by: editor, at: Fixture.start.addingTimeInterval(60))
        #expect(meta.version == 2)
        #expect(meta.updatedBy == editor)
        #expect(meta.createdBy == creator)

        meta.markDeleted(by: editor, at: Fixture.start.addingTimeInterval(120))
        #expect(meta.isDeleted)
        #expect(meta.version == 3)
        meta.markDeleted(by: editor, at: Fixture.start.addingTimeInterval(180))
        #expect(meta.version == 3, "Zweites Löschen ändert nichts")

        meta.restore(by: creator, at: Fixture.start.addingTimeInterval(240))
        #expect(!meta.isDeleted)
        #expect(meta.version == 4)
    }

    @Test func updatedAtNeverMovesBackwards() {
        var meta = EntityMetadata.new(by: nil, at: Fixture.start)
        meta.recordChange(by: nil, at: Fixture.start.addingTimeInterval(-3600))
        #expect(meta.updatedAt == Fixture.start)
    }

    @Test func coordinateValidation() {
        #expect(GeoCoordinate(latitude: 50.3, longitude: 10.2) != nil)
        #expect(GeoCoordinate(latitude: 91, longitude: 0) == nil)
        #expect(GeoCoordinate(latitude: 0, longitude: -181) == nil)
        #expect(GeoCoordinate(latitude: .nan, longitude: 0) == nil)
    }
}

@Suite("Einsatz")
struct MissionTests {
    @Test func titleFallbacks() {
        #expect(Fixture.mission(reason: "  VU B19  ").title == "VU B19")
        #expect(Fixture.mission(type: .brand).title == "Brand")
        #expect(Fixture.mission(yearNumber: 7).title == "Einsatz 7")
        #expect(Fixture.mission(yearNumber: 7).displayNumber(calendar: Fixture.calendar) == "2026/7")
    }

    @Test func closeKeepsExistingEndAndReopenKeepsEnd() {
        var mission = Fixture.mission()
        let plannedEnd = Fixture.start.addingTimeInterval(3600)
        mission.endedAt = plannedEnd
        mission.close(at: Fixture.start.addingTimeInterval(7200))
        #expect(mission.isClosed)
        #expect(mission.endedAt == plannedEnd)

        mission.reopen()
        #expect(!mission.isClosed)
        #expect(mission.endedAt == plannedEnd)
    }

    @Test func closeSetsEndNotBeforeStart() {
        var mission = Fixture.mission()
        mission.close(at: Fixture.start.addingTimeInterval(-60))
        #expect(mission.endedAt == Fixture.start)
    }

    @Test func durationAndDistance() {
        var mission = Fixture.mission()
        #expect(mission.duration(now: Fixture.start.addingTimeInterval(900)) == 900)
        mission.endedAt = Fixture.start.addingTimeInterval(600)
        #expect(mission.duration(now: Fixture.start.addingTimeInterval(900)) == 600)

        mission.odometerStart = 12_000
        mission.odometerEnd = 12_042
        #expect(mission.distanceDriven == 42)
        mission.odometerEnd = 11_000
        #expect(mission.distanceDriven == nil)
    }

    @Test func validation() {
        var mission = Fixture.mission()
        #expect(mission.validate().isEmpty)
        mission.endedAt = Fixture.start.addingTimeInterval(-1)
        mission.odometerStart = 100
        mission.odometerEnd = 50
        #expect(Set(mission.validate()) == [.endBeforeStart, .odometerEndBeforeStart])
        mission.odometerStart = -1
        #expect(mission.validate().contains(.negativeOdometer))
    }

    @Test func yearNumberCountsPerCalendarYear() {
        let existing = [
            Fixture.mission(yearNumber: 1, startedAt: Fixture.date(2025, 12, 31, 23, 30)),
            Fixture.mission(yearNumber: 2, startedAt: Fixture.date(2026, 1, 1, 0, 30)),
            Fixture.mission(yearNumber: 5, startedAt: Fixture.date(2026, 6, 1)),
        ]
        let in2026 = Mission.nextYearNumber(startingAt: Fixture.date(2026, 10, 18), existing: existing, calendar: Fixture.calendar)
        let in2027 = Mission.nextYearNumber(startingAt: Fixture.date(2027, 1, 1), existing: existing, calendar: Fixture.calendar)
        #expect(in2026 == 6)
        #expect(in2027 == 1)
    }
}

@Suite("Abschnitte")
struct MissionSectionTests {
    let missionID = MissionID()

    func section(_ name: String, sortIndex: Int, initial: Bool = false) -> MissionSection {
        MissionSection(
            missionID: missionID,
            metadata: .new(by: Fixture.author, at: Fixture.start),
            name: name,
            sortIndex: sortIndex,
            isInitial: initial
        )
    }

    @Test func nameIsNormalized() {
        #expect(section("  Patientenablage ", sortIndex: 1).name == "Patientenablage")
        #expect(section("   ", sortIndex: 1).name == MissionSection.fallbackName)
    }

    @Test func onlyOneInitialSection() {
        let a = section("Bereitstellungsraum", sortIndex: 1, initial: true)
        let b = section("Patientenablage", sortIndex: 2)
        let c = section("Behandlungsplatz", sortIndex: 3)

        let changes = MissionSection.applyingInitialRule(makeInitial: b.id, in: [a, b, c])
        #expect(changes.count == 2)
        #expect(changes.first { $0.id == a.id }?.isInitial == false)
        #expect(changes.first { $0.id == b.id }?.isInitial == true)

        let none = MissionSection.applyingInitialRule(makeInitial: nil, in: [a, b, c])
        #expect(none.map(\.id) == [a.id])
    }

    @Test func deletedSectionsAreIgnored() {
        var deleted = section("Alt", sortIndex: 9, initial: true)
        deleted.metadata.markDeleted(by: Fixture.author, at: Fixture.start)
        let active = section("Neu", sortIndex: 1)
        #expect(MissionSection.initialSection(in: [deleted, active]) == nil)
        #expect(MissionSection.sorted([deleted, active]).map(\.name) == ["Neu"])
        #expect(MissionSection.nextSortIndex(existing: [deleted, active]) == 10)
    }
}

@Suite("Einheiten")
struct MissionUnitTests {
    let missionID = MissionID()
    let sectionID = SectionID()

    @Test func realUnitNormalization() {
        let unit = MissionUnit(
            missionID: missionID,
            metadata: .new(by: Fixture.author, at: Fixture.start),
            type: .rtw,
            callsign: "  Rotkreuz Musterstadt 71/1 ",
            crewCount: 0
        )
        #expect(unit.displayName == "Rotkreuz Musterstadt 71/1")
        #expect(unit.crewCount == nil)
        #expect(unit.isTemporary)
        #expect(!unit.isPlaceholder)
    }

    @Test func placeholdersForStichwortAreNumberedConsecutively() {
        let existing = MissionUnit(
            missionID: missionID,
            metadata: .new(by: Fixture.author, at: Fixture.start),
            placeholderType: .ktw,
            number: 2
        )
        let created = MissionUnit.placeholders(
            for: .rd3,
            missionID: missionID,
            sectionID: sectionID,
            existing: [existing],
            author: Fixture.author,
            at: Fixture.start
        )
        #expect(created.map(\.type) == [.rtw, .rtw, .nef])
        #expect(created.map(\.placeholderNumber) == [3, 4, 5])
        #expect(created.allSatisfy { $0.sectionID == sectionID && $0.isPlaceholder })
        #expect(created[2].displayName == "NEF (Platzhalter 5)")
    }

    @Test func replacingPlaceholderKeepsIdentityAndSection() {
        var unit = MissionUnit(
            missionID: missionID,
            metadata: .new(by: Fixture.author, at: Fixture.start),
            placeholderType: .rtw,
            number: 1,
            sectionID: sectionID
        )
        let originalID = unit.id
        let master = MasterUnitID()
        let replaced = unit.replacePlaceholder(callsign: "Florian 1/83", type: .nef, crewCount: 2, masterUnitID: master)

        #expect(replaced)
        #expect(unit.id == originalID)
        #expect(unit.sectionID == sectionID)
        #expect(!unit.isPlaceholder)
        #expect(unit.type == .nef)
        #expect(unit.displayName == "Florian 1/83")
        #expect(unit.masterUnitID == master)
        #expect(!unit.isTemporary)
        let replacedTwice = unit.replacePlaceholder(callsign: "X", type: .rtw, crewCount: nil, masterUnitID: nil)
        #expect(!replacedTwice, "Eine reale Einheit ist kein Platzhalter mehr")
        #expect(unit.displayName == "Florian 1/83")
    }

    @Test func renameOnlyAffectsRealUnits() {
        var placeholder = MissionUnit(
            missionID: missionID,
            metadata: .new(by: Fixture.author, at: Fixture.start),
            placeholderType: .ktw,
            number: 1
        )
        placeholder.rename(to: "Test")
        #expect(placeholder.callsign == nil)
    }

    @Test func sortingPutsRealUnitsFirst() {
        let meta = EntityMetadata.new(by: Fixture.author, at: Fixture.start)
        let units = [
            MissionUnit(missionID: missionID, metadata: meta, placeholderType: .rtw, number: 2),
            MissionUnit(missionID: missionID, metadata: meta, type: .nef, callsign: "NEF 1"),
            MissionUnit(missionID: missionID, metadata: meta, placeholderType: .rtw, number: 1),
            MissionUnit(missionID: missionID, metadata: meta, type: .rtw, callsign: "RTW 10"),
            MissionUnit(missionID: missionID, metadata: meta, type: .rtw, callsign: "RTW 2"),
        ]
        #expect(MissionUnit.sorted(units).map(\.displayName) == [
            "RTW 2", "RTW 10", "NEF 1", "RTW (Platzhalter 1)", "RTW (Platzhalter 2)",
        ])
    }
}
