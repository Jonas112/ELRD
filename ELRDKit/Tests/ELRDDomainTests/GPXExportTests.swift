import Foundation
import Testing
@testable import ELRDDomain

@Suite("GPX für Garmin (Schritt 119)")
struct GPXExportTests {
    private func point(_ latitude: Double, _ longitude: Double) -> GeoCoordinate {
        GeoCoordinate(latitude: latitude, longitude: longitude)!
    }

    @Test func circleBecomesClosedTrack() throws {
        let object = try #require(MapObject(missionID: Sample.missionID, metadata: Sample.meta(), title: "Gefahr <A&B>",
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
        var polygon = try #require(MapObject(missionID: Sample.missionID, metadata: Sample.meta(), title: "Sperrzone",
                                             shape: .circle(center: point(50, 10), radiusMeters: 10)))
        let polygonSet = polygon.setPath(MapPath(kind: .polygon, points: [point(50, 10), point(50.001, 10), point(50.001, 10.001)]))
        #expect(polygonSet)
        #expect(GPXExport.items(for: polygon).tracks.first?.points.count == 4)

        var arrow = try #require(MapObject(missionID: Sample.missionID, metadata: Sample.meta(), title: "Zufahrt",
                                           shape: .circle(center: point(50, 10), radiusMeters: 10)))
        let arrowSet = arrow.setPath(MapPath(kind: .arrow, points: [point(50, 10), point(50.002, 10.002)]))
        #expect(arrowSet)
        let arrowTrack = try #require(GPXExport.items(for: arrow).tracks.first)
        #expect(arrowTrack.points.count == 2)
        #expect(arrowTrack.points.first != arrowTrack.points.last)

        var sign = try #require(MapObject(missionID: Sample.missionID, metadata: Sample.meta(),
                                          shape: .circle(center: point(50.1, 10.1), radiusMeters: 10)))
        sign.tacticalSign = TacticalSign(base: .stelle, organisation: .hilfsorganisation, text: "BR", presetID: "br")
        let items = GPXExport.items(for: sign)
        #expect(items.tracks.isEmpty)
        #expect(items.waypoints.first?.name == "Bereitstellungsraum")
        #expect(items.waypoints.first?.coordinate == point(50.1, 10.1))
    }

    @Test func rectangleHasFiveCorners() throws {
        let bounds = try #require(GeoBounds(north: 50.01, south: 50, east: 10.01, west: 10))
        let object = try #require(MapObject(missionID: Sample.missionID, metadata: Sample.meta(), shape: .rectangle(bounds: bounds)))
        let points = try #require(GPXExport.items(for: object).tracks.first?.points)
        #expect(points.count == 5)
        #expect(points.first == points.last)
    }

    @Test func fileNameIsSafe() {
        #expect(GPXExport.fileName("Lagekarte VU/B 19") == "Lagekarte_VU-B_19.gpx")
        #expect(GPXExport.fileName("  ") == "Lagekarte.gpx")
    }
}
