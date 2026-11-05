import Foundation
import Testing
@testable import ELRDDomain
@testable import ELRDFeatures

@Suite("Körpergrafik und Kachelansicht")
struct BodyDiagramTests {
    @Test func everyRegionAndSideHasExactlyOnePart() {
        let spots = BodyPart.all.map(\.spot)
        #expect(Set(spots).count == spots.count)
        for region in BodyRegion.allCases {
            let sides: [BodySide?] = region.hasSide ? BodySide.allCases : [nil]
            for side in sides {
                #expect(spots.contains(BodySpot(region, side)), "\(region) \(String(describing: side)) fehlt")
            }
        }
    }

    @Test func tapAreasDoNotOverlapAndContainDrawing() {
        let canvas = CGRect(origin: .zero, size: BodyPart.canvas)
        for (index, part) in BodyPart.all.enumerated() {
            #expect(canvas.contains(part.hit), "\(part.spot.title) außerhalb")
            #expect(part.hit.contains(part.drawn), "\(part.spot.title): Zeichnung außerhalb der Tippfläche")
            #expect(part.hit.width >= 44 && part.hit.height >= 44, "\(part.spot.title) zu klein zum Tippen")
            for other in BodyPart.all[(index + 1)...] {
                #expect(part.hit.intersection(other.hit).isEmpty, "\(part.spot.title) überlappt \(other.spot.title)")
            }
        }
    }

    @Test func patientsRightSideIsOnTheLeftOfTheDrawing() throws {
        let right = try #require(BodyPart.all.first { $0.spot == BodySpot(.arm, .rechts) })
        let left = try #require(BodyPart.all.first { $0.spot == BodySpot(.arm, .links) })
        #expect(right.drawn.midX < left.drawn.midX, "Vorderansicht: rechte Seite des Patienten links im Bild")
    }

    @Test func countsPerSpot() {
        let injuries = [
            Injury(diagnosis: "Unterschenkel#", region: .unterschenkel, side: .rechts),
            Injury(diagnosis: "Prellung", region: .unterschenkel, side: .rechts),
            Injury(diagnosis: "Schürfwunde", region: .arm),
            Injury(diagnosis: "Rippen#", region: .thorax, side: .links),
            Injury(diagnosis: "unklar"),
        ]
        let counts = BodyPart.counts(for: injuries)
        #expect(counts[BodySpot(.unterschenkel, .rechts)] == 2)
        #expect(counts[BodySpot(.arm, .rechts)] == 1, "Extremität ohne Seite zählt auf beiden Seiten")
        #expect(counts[BodySpot(.arm, .links)] == 1)
        #expect(counts[BodySpot(.thorax)] == 1, "Seite am Rumpf wird ignoriert")
        #expect(counts.values.reduce(0, +) == 5)
        #expect(BodySpot(.thorax, .links).title == "Thorax")
        #expect(BodySpot(.hand, .links).title == "Hand links")
    }

    @Test func listLayoutSurvivesTriageFilter() {
        var query = PatientListQuery(layout: .tiles)
        query = PatientListQuery(triage: .sk1, sort: query.sort, layout: query.layout)
        #expect(query.layout == .tiles)
        #expect(PatientListQuery().layout == .list)
    }
}
