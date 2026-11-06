import Foundation
import Testing
@testable import ELRDDomain
@testable import ELRDPersistence
@testable import ELRDStore

@Suite("Kreise und Rechtecke auf der Karte")
@MainActor
struct MapObjectCommandTests {
    let center = GeoCoordinate(latitude: 50.10, longitude: 10.18)!

    @Test func circleIsAddedEditedMovedAndDeleted() throws {
        let fixture = try StoreFixture()
        let store = try fixture.newMission()
        let circle = try store.perform(AddMapObject(shape: .circle(center: center, radiusMeters: 100), title: " Gefahrenbereich "))
        #expect(circle.title == "Gefahrenbereich")
        #expect(store.state.visibleLog.last?.message == "„Gefahrenbereich“ auf der Karte angelegt (Radius 100 m)")

        try store.perform(EditMapObject(objectID: circle.id, shape: .circle(center: center, radiusMeters: 250)))
        #expect(store.state.visibleLog.last?.message == "„Gefahrenbereich“ geändert (Radius 250 m)")

        let elsewhere = try #require(GeoCoordinate(latitude: 50.11, longitude: 10.19))
        try store.perform(EditMapObject(objectID: circle.id, shape: .circle(center: elsewhere, radiusMeters: 250)))
        #expect(store.state.visibleLog.last?.message == "„Gefahrenbereich“ verschoben")

        let count = store.state.visibleLog.count
        try store.perform(EditMapObject(objectID: circle.id, title: "Gefahrenbereich"))
        #expect(store.state.visibleLog.count == count, "unverändert, kein Eintrag")

        #expect(throws: CommandError.invalid("Diese Form ist ungültig (Radius 1 m bis 50 km).")) {
            try store.perform(EditMapObject(objectID: circle.id, shape: .circle(center: center, radiusMeters: 0)))
        }

        try store.perform(DeleteMapObject(objectID: circle.id))
        #expect(store.state.mapObjects.active.isEmpty)
        #expect(store.state.visibleLog.last?.message == "„Gefahrenbereich“ von der Karte gelöscht")
    }

    @Test func rectangleKeepsSizeWhenMoved() throws {
        let bounds = try #require(GeoBounds.around(center, widthMeters: 200, heightMeters: 100))
        #expect(abs(bounds.widthMeters - 200) < 1)
        #expect(abs(bounds.heightMeters - 100) < 1)
        #expect(MapShape.rectangle(bounds: bounds).sizeText == "200 × 100 m")

        let target = try #require(GeoCoordinate(latitude: 50.2, longitude: 10.3))
        let moved = MapShape.rectangle(bounds: bounds).moved(to: target)
        #expect(abs(moved.center.latitude - 50.2) < 0.00001)
        #expect(moved.sizeText == "200 × 100 m")
        #expect(MapShape.metersText(1500) == "1,5 km")
        #expect(MapShape.metersText(2000) == "2 km")
    }
}

@Suite("Freihandzeichnung auf der Karte")
@MainActor
struct DrawingObjectTests {
    @Test func drawingIsStoredWithImageAndCanBeMoved() throws {
        let fixture = try StoreFixture()
        let store = try fixture.newMission()
        let center = try #require(GeoCoordinate(latitude: 50.10, longitude: 10.18))
        let bounds = try #require(GeoBounds.around(center, widthMeters: 160, heightMeters: 90))
        let image = FileAttachment(kind: .drawing, byteCount: 10, sha256: String(repeating: "a", count: 64), createdAt: Date())
        let drawing = try store.perform(AddMapObject(shape: .drawing(bounds: bounds, image: image)))
        #expect(drawing.displayName == "Zeichnung")
        #expect(drawing.shape.isDrawing)
        #expect(store.state.visibleLog.last?.message == "„Zeichnung“ auf der Karte angelegt (160 × 90 m)")

        let photo = FileAttachment(kind: .photo, byteCount: 10, sha256: String(repeating: "b", count: 64), createdAt: Date())
        #expect(throws: CommandError.self) {
            try store.perform(AddMapObject(shape: .drawing(bounds: bounds, image: photo)))
        }

        let target = try #require(GeoCoordinate(latitude: 50.11, longitude: 10.19))
        try store.perform(EditMapObject(objectID: drawing.id, shape: drawing.shape.moved(to: target)))
        let moved = try #require(store.state.mapObjects.active.first)
        #expect(moved.shape.sizeText == "160 × 90 m")
        #expect(abs(moved.shape.center.latitude - 50.11) < 0.00001)
    }
}
