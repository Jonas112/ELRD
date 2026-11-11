import Foundation
import Testing
@testable import ELRDDomain
@testable import ELRDStore

@Suite("Kommunikationsplan, taktische Zeichen, Polygon und Pfeil (Schritte 112–115)")
@MainActor
struct MapAndCommunicationTests {
    let fixture: StoreFixture

    init() throws {
        fixture = try StoreFixture()
    }

    private func point(_ latitude: Double, _ longitude: Double) -> GeoCoordinate {
        GeoCoordinate(latitude: latitude, longitude: longitude)!
    }

    // MARK: 112 Kommunikationsplan

    @Test func communicationPlanGroupsChannels() throws {
        let store = try fixture.newMission(sections: ["Bereitstellungsraum", "Patientenablage"])
        try store.perform(SetLeadershipPosition(LeadershipPosition(role: .einsatzleiter, name: "E. Beispiel", callsign: "ELRD 1", radioChannel: "TMO 312")))
        try store.perform(SetLeadershipPosition(LeadershipPosition(role: .lna, name: "Dr. Weber", callsign: "LNA SW", radioChannel: "TMO 312")))
        let sections = store.state.sections.active
        let ablage = try #require(sections.first { $0.name == "Patientenablage" })
        try store.perform(SetSectionLeader(sectionID: ablage.id, name: "S. Lang", callsign: "RK SWF 10/1", radioChannel: "TMO 313"))
        let unit = try store.perform(AddTemporaryUnit(callsign: "RK 1", type: .rtw))
        try store.perform(MoveUnit(unitID: unit.id, to: ablage.id))

        let plan = CommunicationPlan(store.state)
        #expect(plan.channels.map(\.name) == ["TMO 312", "TMO 313"])
        #expect(plan.channels.first?.members == ["ELRD (ELRD 1)", "LNA (LNA SW)"])
        #expect(plan.leadership.map(\.function) == ["ELRD", "LNA"])
        let entry = try #require(plan.sections.first { $0.function == "Patientenablage" })
        #expect(entry.units == ["RK 1"])
        #expect(plan.text.contains("TMO 313: Patientenablage (RK SWF 10/1)"))
        #expect(plan.text.contains("  Einheiten: RK 1"))
        let html = plan.html(printedAt: "10.11.2026, 12:00")
        #expect(html.contains("<td>TMO 313</td>"))
        #expect(!html.contains("<script"))
    }

    @Test func communicationPlanEscapesHTML() throws {
        let store = try fixture.newMission(sections: ["A<B>"])
        let html = CommunicationPlan(store.state).html(printedAt: "jetzt")
        #expect(html.contains("A&lt;B&gt;"))
    }

    // MARK: 114 Taktische Zeichen

    @Test func addsTacticalSignAsSmallCircle() throws {
        let store = try fixture.newMission()
        let preset = try #require(TacticalSignPreset.preset("rtw"))
        let object = try store.perform(AddMapObject.sign(preset.sign, at: point(50, 10)))
        #expect(object.tacticalSign?.base == .kraftfahrzeug)
        #expect(object.tacticalSign?.task == .rettungswesen)
        #expect(object.shape == .circle(center: point(50, 10), radiusMeters: 10), "ältere Apps sehen einen kleinen Kreis")
        #expect(object.displayName == "Rettungswagen (RTW)")
        #expect(!object.isResizable)

        var changed = preset.sign
        changed.text = "RTW 2"
        try store.perform(EditMapObject(objectID: object.id, tacticalSign: changed))
        #expect(store.state.mapObjects.first?.tacticalSign?.text == "RTW 2")
    }

    @Test func tacticalSignToleratesUnknownValues() throws {
        let json = #"{"baseRaw":"raumschiff","organisationRaw":"weltraum","text":"X"}"#
        let sign = try JSONDecoder().decode(TacticalSign.self, from: Data(json.utf8))
        #expect(sign.base == .stelle)
        #expect(sign.organisation == .hilfsorganisation)
        #expect(sign.text == "X")
        #expect(TacticalSign(base: .stelle, organisation: .feuerwehr, text: "  ABCDEFGHIJ ").text == "ABCDEFGH", "höchstens 8 Zeichen")
    }

    @Test func presetsAreUnique() {
        let ids = TacticalSignPreset.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(TacticalSignPreset.all.allSatisfy { $0.sign.presetID == $0.id })
    }

    // MARK: 115 Polygon und Pfeil

    @Test func pathNeedsEnoughPoints() throws {
        #expect(AddMapObject.withPath(MapPath(kind: .polygon, points: [point(50, 10), point(50.001, 10)])) == nil)
        #expect(AddMapObject.withPath(MapPath(kind: .arrow, points: [point(50, 10)])) == nil)
        #expect(AddMapObject.withPath(MapPath(kind: .arrow, points: [point(50, 10), point(50.001, 10)])) != nil)
    }

    @Test func newAreasAreNumberedAutomatically() throws {
        let store = try fixture.newMission()
        let path = MapPath(kind: .polygon, points: [point(50.000, 10.000), point(50.002, 10.000), point(50.001, 10.003)])
        let first = try store.perform(try #require(AddMapObject.withPath(path)))
        let bounds = try #require(GeoBounds(north: 50.01, south: 50, east: 10.01, west: 10))
        let second = try store.perform(AddMapObject(shape: .rectangle(bounds: bounds)))
        let circle = try store.perform(AddMapObject(shape: .circle(center: point(50, 10), radiusMeters: 50)))
        let arrow = try store.perform(try #require(AddMapObject.withPath(MapPath(kind: .arrow, points: [point(50, 10), point(50.001, 10)]))))
        let named = try store.perform(try #require(AddMapObject.withPath(path, title: "Sperrzone")))
        #expect(first.title == "Suchgebiet 1")
        #expect(second.title == "Suchgebiet 2")
        #expect(circle.title.isEmpty, "Kreise bleiben ohne automatische Bezeichnung")
        #expect(arrow.title.isEmpty)
        #expect(named.title == "Sperrzone")
    }

    @Test func polygonStoresBoundingRectangleAndMovesAsWhole() throws {
        let store = try fixture.newMission()
        let path = MapPath(kind: .polygon, points: [point(50.000, 10.000), point(50.002, 10.000), point(50.001, 10.003)])
        let command = try #require(AddMapObject.withPath(path, title: "Sperrzone"))
        let object = try store.perform(command)
        guard case let .rectangle(bounds) = object.shape else {
            Issue.record("Ersatzform muss ein Rechteck sein")
            return
        }
        #expect(abs(bounds.north - 50.002) < 1e-9)
        #expect(abs(bounds.east - 10.003) < 1e-9)
        #expect(object.path?.points.count == 3)
        #expect(object.sizeText == "Fläche, 3 Ecken")

        let moved = path.moved(to: point(50.011, 10.0115))
        try store.perform(EditMapObject(objectID: object.id, path: moved))
        let after = try #require(store.state.mapObjects.first)
        #expect(abs((after.path?.points.first?.latitude ?? 0) - 50.010) < 1e-9, "alle Punkte um denselben Versatz")
        #expect(abs(after.shape.center.latitude - 50.011) < 1e-9)
        #expect(store.state.logEntries.contains { $0.message.hasPrefix("„Sperrzone“") && ($0.message.contains("verschoben") || $0.message.contains("geändert")) })
    }

    @Test func arrowSummaryShowsLength() {
        let arrow = MapPath(kind: .arrow, points: [point(50.0, 10.0), point(50.009, 10.0)])
        #expect(arrow.summary == "Pfeil, 1,0 km" || arrow.summary == "Pfeil, 1 km")
        #expect(MapPath(kind: .arrow, points: [point(50, 10), point(50, 10)]).bounds != nil, "auch ohne Ausdehnung ein Rechteck")
    }

    @Test func pathDecodingToleratesUnknownKind() throws {
        let json = #"{"kindRaw":"spirale","points":[{"latitude":50,"longitude":10},{"latitude":50.1,"longitude":10}]}"#
        let path = try JSONDecoder().decode(MapPath.self, from: Data(json.utf8))
        #expect(path.kind == .arrow)
        #expect(path.isValid)
    }
}
