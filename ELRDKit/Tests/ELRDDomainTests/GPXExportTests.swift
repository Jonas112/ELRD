import Foundation
import Testing
@testable import ELRDDomain

private enum GPXSample {
    static let missionID = MissionID()
    static func meta() -> EntityMetadata { .new(by: nil, at: Date(timeIntervalSince1970: 1_800_000_000)) }
}

@Suite("GPX für Garmin (Schritt 119)")
struct GPXExportTests {
    private func point(_ latitude: Double, _ longitude: Double) -> GeoCoordinate {
        GeoCoordinate(latitude: latitude, longitude: longitude)!
    }

    @Test func circleBecomesClosedTrack() throws {
        let object = try #require(MapObject(missionID: GPXSample.missionID, metadata: GPXSample.meta(), title: "Gefahr <A&B>",
                                            shape: .circle(center: point(50, 10), radiusMeters: 100)))
        let items = GPXExport.items(for: object)
        let track = try #require(items.tracks.first)
        #expect(track.points.count == GPXExport.circleSegments + 1)
        #expect(track.points.first == track.points.last, "geschlossen")
        let distances = track.points.map { $0.distance(to: point(50, 10)) }
        #expect(distances.allSatisfy { abs($0 - 100) < 1.5 }, "alle Punkte ca. 100 m vom Mittelpunkt")
        let xml = GPXExport.document(for: object, createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(xml.contains("<name>Gefahr &lt;A&amp;B&gt;</name>"))
        #expect(xml.contains(#"<trkpt lat="50.0008983" lon="10.0000000"/>"#))
        #expect(xml.contains("<time>2027-01-15T08:00:00Z</time>"))
        #expect(xml.hasPrefix(#"<?xml version="1.0" encoding="UTF-8"?>"#))
    }

    @Test func polygonClosedArrowOpenSignAsWaypoint() throws {
        var polygon = try #require(MapObject(missionID: GPXSample.missionID, metadata: GPXSample.meta(), title: "Sperrzone",
                                             shape: .circle(center: point(50, 10), radiusMeters: 10)))
        let polygonSet = polygon.setPath(MapPath(kind: .polygon, points: [point(50, 10), point(50.001, 10), point(50.001, 10.001)]))
        #expect(polygonSet)
        #expect(GPXExport.items(for: polygon).tracks.first?.points.count == 4)

        var arrow = try #require(MapObject(missionID: GPXSample.missionID, metadata: GPXSample.meta(), title: "Zufahrt",
                                           shape: .circle(center: point(50, 10), radiusMeters: 10)))
        let arrowSet = arrow.setPath(MapPath(kind: .arrow, points: [point(50, 10), point(50.002, 10.002)]))
        #expect(arrowSet)
        let arrowTrack = try #require(GPXExport.items(for: arrow).tracks.first)
        #expect(arrowTrack.points.count == 2)
        #expect(arrowTrack.points.first != arrowTrack.points.last)

        var sign = try #require(MapObject(missionID: GPXSample.missionID, metadata: GPXSample.meta(),
                                          shape: .circle(center: point(50.1, 10.1), radiusMeters: 10)))
        sign.tacticalSign = TacticalSign(base: .stelle, organisation: .hilfsorganisation, text: "BR", presetID: "br")
        let items = GPXExport.items(for: sign)
        #expect(items.tracks.isEmpty)
        #expect(items.waypoints.first?.name == "Bereitstellungsraum")
        #expect(items.waypoints.first?.coordinate == point(50.1, 10.1))
    }

    @Test func rectangleHasFiveCorners() throws {
        let bounds = try #require(GeoBounds(north: 50.01, south: 50, east: 10.01, west: 10))
        let object = try #require(MapObject(missionID: GPXSample.missionID, metadata: GPXSample.meta(), shape: .rectangle(bounds: bounds)))
        let points = try #require(GPXExport.items(for: object).tracks.first?.points)
        #expect(points.count == 5)
        #expect(points.first == points.last)
    }

    // MARK: Schritt 123: Beschriftung

    @Test func labelBecomesWaypointAtCentroid() throws {
        var area = try #require(MapObject(missionID: GPXSample.missionID, metadata: GPXSample.meta(), title: "Suchgebiet 2",
                                          shape: .circle(center: point(50, 10), radiusMeters: 10)))
        let isSet = area.setPath(MapPath(kind: .polygon, points: [point(50, 10), point(50.003, 10), point(50, 10.003)]))
        #expect(isSet)
        let items = GPXExport.items(for: area)
        let label = try #require(items.waypoints.first)
        #expect(label.name == "Suchgebiet 2")
        #expect(abs(label.coordinate.latitude - 50.001) < 1e-9)
        #expect(abs(label.coordinate.longitude - 10.001) < 1e-9)
        #expect(items.tracks.first?.name == "Suchgebiet 2")
        #expect(items.tracks.first?.description == "Fläche, 3 Ecken")
        let xml = GPXExport.document(for: area, createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(xml.contains("<wpt "))
        #expect(xml.contains("<sym>Flag, Green</sym>"))
        #expect(xml.components(separatedBy: "<name>Suchgebiet 2</name>").count == 4, "Metadaten, Wegpunkt und Track")
    }

    @Test func unnamedShapeHasNoLabelWaypoint() throws {
        let bounds = try #require(GeoBounds(north: 50.01, south: 50, east: 10.01, west: 10))
        let object = try #require(MapObject(missionID: GPXSample.missionID, metadata: GPXSample.meta(), shape: .rectangle(bounds: bounds)))
        #expect(GPXExport.items(for: object).waypoints.isEmpty)
    }

    @Test func nextSearchAreaNumber() throws {
        func object(_ title: String) throws -> MapObject {
            try #require(MapObject(missionID: GPXSample.missionID, metadata: GPXSample.meta(), title: title,
                                   shape: .circle(center: point(50, 10), radiusMeters: 10)))
        }
        #expect(MapObject.nextSearchAreaTitle(existing: []) == "Suchgebiet 1")
        let existing = [try object("Suchgebiet 1"), try object("Suchgebiet 4"), try object("Sperrzone"), try object("Suchgebiet Nord")]
        #expect(MapObject.nextSearchAreaTitle(existing: existing) == "Suchgebiet 5")
    }

    @Test func fileNameIsSafe() {
        #expect(GPXExport.fileName("Lagekarte VU/B 19") == "Lagekarte_VU-B_19.gpx")
        #expect(GPXExport.fileName("  ") == "Lagekarte.gpx")
    }
}
