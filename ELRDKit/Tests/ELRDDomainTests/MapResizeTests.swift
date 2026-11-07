import Foundation
import Testing
@testable import ELRDDomain

@Suite("Formen direkt auf der Karte ändern (Schritt 60)")
struct MapResizeTests {
    let center = GeoCoordinate(latitude: 50.05, longitude: 10.23)!

    @Test func circleHandleSitsOnEastEdgeAndSetsRadius() throws {
        let circle = MapShape.circle(center: center, radiusMeters: 100)
        let handle = try #require(circle.resizeHandle)
        #expect(handle.latitude == center.latitude)
        #expect(handle.longitude > center.longitude)
        // Griff an derselben Stelle → gleicher Radius.
        guard case let .circle(_, same) = circle.resized(handle: handle) else { Issue.record("kein Kreis"); return }
        #expect(abs(same - 100) < 0.5)
        // Griff 200 m nach Norden → Radius 200 m, Mittelpunkt bleibt.
        let north = GeoCoordinate(latitude: center.latitude + 200 / 111_320.0, longitude: center.longitude)!
        guard case let .circle(kept, radius) = circle.resized(handle: north) else { Issue.record("kein Kreis"); return }
        #expect(kept == center)
        #expect(abs(radius - 200) < 0.5)
        // Griff auf den Mittelpunkt → Mindestgröße.
        guard case let .circle(_, tiny) = circle.resized(handle: center) else { Issue.record("kein Kreis"); return }
        #expect(tiny == MapShape.minimumSizeMeters)
    }

    @Test func rectangleKeepsNorthWestCorner() throws {
        let bounds = try #require(GeoBounds.around(center, widthMeters: 200, heightMeters: 100))
        let rectangle = MapShape.rectangle(bounds: bounds)
        let handle = try #require(rectangle.resizeHandle)
        #expect(handle.latitude == bounds.south && handle.longitude == bounds.east)

        let bigger = GeoCoordinate(latitude: bounds.south - 0.001, longitude: bounds.east + 0.001)!
        guard case let .rectangle(grown) = rectangle.resized(handle: bigger) else { Issue.record("kein Rechteck"); return }
        #expect(grown.north == bounds.north && grown.west == bounds.west)
        #expect(grown.south == bigger.latitude && grown.east == bigger.longitude)

        // Über die Nordwest-Ecke hinaus gezogen → bleibt mindestens 5 m groß.
        let beyond = GeoCoordinate(latitude: bounds.north + 0.01, longitude: bounds.west - 0.01)!
        guard case let .rectangle(small) = rectangle.resized(handle: beyond) else { Issue.record("kein Rechteck"); return }
        #expect(small.heightMeters >= MapShape.minimumSizeMeters - 0.01)
        #expect(small.widthMeters >= MapShape.minimumSizeMeters * 0.99)
        #expect(small.north == bounds.north && small.west == bounds.west)
    }
}
