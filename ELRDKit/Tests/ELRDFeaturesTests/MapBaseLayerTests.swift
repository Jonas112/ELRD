import Foundation
import Testing
import MapKit
@testable import ELRDDomain
@testable import ELRDFeatures
import ELRDStore

@Suite("Lagekarte: Grundlage und Einsatzort")
@MainActor
struct MapBaseLayerTests {
    @Test func tileLayersHaveTemplateAndAttribution() {
        for layer in MapBaseLayer.allCases {
            let usesTiles = [.openStreetMap, .openTopoMap].contains(layer)
            #expect((layer.tileTemplate != nil) == usesTiles, "\(layer)")
            #expect((layer.attribution != nil) == usesTiles, "Lizenzhinweis \(layer)")
            if let template = layer.tileTemplate {
                #expect(template.hasPrefix("https://"))
                #expect(template.contains("{z}/{x}/{y}"))
            }
        }
        #expect(MapBaseLayer.openTopoMap.maximumZoom == 17)
        #expect(MapBaseLayer(rawValue: "unbekannt") == nil)
    }

    @Test func initialRegionUsesMissionLocation() throws {
        let place = try #require(GeoCoordinate(latitude: 50.10, longitude: 10.18))
        let region = MapCanvas.initialRegion(around: place)
        #expect(abs(region.center.latitude - 50.10) < 0.0001)
        #expect(region.span.latitudeDelta < 0.05, "Straßenebene")
        #expect(MapCanvas.initialRegion(around: nil).span.latitudeDelta > 5, "ganz Deutschland")
        let far = try #require(GeoCoordinate(latitude: 50.12, longitude: 10.18))
        let wide = MapCanvas.initialRegion(around: place, including: [far])
        #expect(wide.span.latitudeDelta >= 0.02 * 1.6 - 0.0001, "alles im Bild")
        #expect(abs(wide.center.latitude - 50.11) < 0.0001)
    }

    @Test func missionCoordinateIsSetMovedAndLogged() throws {
        let store = try PreviewData.makeStore()
        let first = try #require(GeoCoordinate(latitude: 50.10, longitude: 10.18))
        let second = try #require(GeoCoordinate(latitude: 50.11, longitude: 10.19))
        try store.perform(SetMissionCoordinate(first))
        #expect(store.state.mission.coordinate == first)
        #expect(store.state.visibleLog.last?.message == "Einsatzort auf der Karte gesetzt")
        try store.perform(SetMissionCoordinate(second))
        #expect(store.state.visibleLog.last?.message == "Einsatzort auf der Karte verschoben")
        let count = store.state.visibleLog.count
        try store.perform(SetMissionCoordinate(second))
        #expect(store.state.visibleLog.count == count, "unverändert, kein Eintrag")
    }
}
