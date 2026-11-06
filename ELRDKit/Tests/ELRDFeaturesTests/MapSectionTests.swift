import Foundation
import Testing
@testable import ELRDDomain
@testable import ELRDFeatures
import ELRDStore

@Suite("Abschnitte auf der Karte")
@MainActor
struct MapSectionTests {
    @Test func sectionsArePlacedMovedAndRemoved() throws {
        let store = try PreviewData.makeStore() // 3 Abschnitte, RD 3 im Bereitstellungsraum
        let staging = store.state.activeSections[0]
        let first = try #require(GeoCoordinate(latitude: 50.10, longitude: 10.18))
        let second = try #require(GeoCoordinate(latitude: 50.11, longitude: 10.19))

        #expect(MapSectionPin.pins(for: store.state).allSatisfy { $0.coordinate == nil })
        try store.perform(SetSectionCoordinate(sectionID: staging.id, coordinate: first))
        #expect(store.state.visibleLog.last?.message == "Abschnitt „Bereitstellungsraum“ auf der Karte gesetzt")
        try store.perform(SetSectionCoordinate(sectionID: staging.id, coordinate: second))
        #expect(store.state.visibleLog.last?.message == "Abschnitt „Bereitstellungsraum“ auf der Karte verschoben")

        let pins = MapSectionPin.pins(for: store.state)
        #expect(pins.map(\.name) == ["Bereitstellungsraum", "Patientenablage", "Behandlungsplatz"])
        #expect(pins[0].coordinate == second)
        #expect(pins[0].summary == "2 RTW · 1 NEF")
        #expect(pins[0].isInitial)

        try store.perform(SetSectionCoordinate(sectionID: staging.id, coordinate: nil))
        #expect(store.state.visibleLog.last?.message == "Abschnitt „Bereitstellungsraum“ von der Karte genommen")
        #expect(MapSectionPin.pins(for: store.state)[0].coordinate == nil)
    }

    @Test func sectionPayloadIsNotAnOrganisationDrop() throws {
        let store = try PreviewData.makeStore()
        let section = store.state.activeSections[0]
        #expect(DragPayload(text: DragPayload.section(section.id).text) == .section(section.id))
        #expect(DropAction.actions(for: .section(section.id), onto: .section(nil), in: store.state).isEmpty)
    }
}

@Suite("Markierungen: Größe ändern")
struct MapObjectPaletteTests {
    @Test func scalingStaysInAllowedRange() throws {
        let center = try #require(GeoCoordinate(latitude: 50.1, longitude: 10.18))
        #expect(MapObjectPalette.scaled(.circle(center: center, radiusMeters: 100), by: 1.25) == .circle(center: center, radiusMeters: 125))
        #expect(MapObjectPalette.scaled(.circle(center: center, radiusMeters: 1), by: 0.8) == .circle(center: center, radiusMeters: 1))
        let rectangle = try #require(MapObjectPalette.newRectangle(at: center))
        #expect(rectangle.sizeText == "100 × 50 m")
        #expect(MapObjectPalette.scaled(rectangle, by: 2).sizeText == "200 × 100 m")
        #expect(MapObjectPalette.newCircle(at: center).isCircle)
    }
}
