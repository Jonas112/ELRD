import Foundation
import Testing
@testable import ELRDDomain
@testable import ELRDFeatures
@testable import ELRDStore

@Suite("Vorlagen je Einsatzart (106) und Nachbesprechung (107)")
@MainActor
struct TemplateDebriefTests {
    @Test func templateAddsSectionsAndInitial() {
        let template = MissionTypeSetting(type: .brand, sectionNames: ["Atemschutz-Sammelplatz", " ", "patientenablage", "Dekon"],
                                          initialSectionName: "Dekon", alarmstichwort: .rd3)
        #expect(template.templateSections == ["Atemschutz-Sammelplatz", "patientenablage", "Dekon"])
        #expect(template.alarmstichwort == .rd3)
        let merged = MissionTemplateSections.merge(master: ["Bereitstellungsraum", "Patientenablage"], masterInitial: "Bereitstellungsraum", template: template)
        #expect(merged.names == ["Bereitstellungsraum", "Patientenablage", "Atemschutz-Sammelplatz", "Dekon"], "doppelte Namen (Groß/klein) nur einmal")
        #expect(merged.initial == "Dekon")
        #expect(MissionTemplateSections.merge(master: ["A"], masterInitial: "A", template: nil).initial == "A")

        var form = NewMissionForm()
        form.type = .brand
        let request = form.request(automaticSections: [], template: template)
        #expect(request.sectionNames == ["Atemschutz-Sammelplatz", "patientenablage", "Dekon"])
        #expect(request.initialSectionName == "Dekon")
        form.type = .verkehrsunfall
        #expect(form.request(automaticSections: [], template: template).sectionNames.isEmpty, "Vorlage gilt nur für ihre Art")
    }

    @Test func templateSurvivesUnknownStichwortAndOldSettings() throws {
        let json = #"{"type":"Brand","checklistID":null,"alarmstichwortRaw":"RD 9"}"#
        let decoded = try JSONDecoder().decode(MissionTypeSetting.self, from: Data(json.utf8))
        #expect(decoded.alarmstichwort == nil)
        let old = try JSONDecoder().decode(MissionTypeSetting.self, from: Data(#"{"type":"VU"}"#.utf8))
        #expect(!old.hasTemplate)
        var settings = AppSettings()
        settings.missionTypes = [MissionTypeSetting(type: .brand, alarmstichwort: .rd2)]
        #expect(settings.template(for: .brand)?.alarmstichwort == .rd2)
        #expect(settings.template(for: nil) == nil)
    }

    @Test func debriefIsSavedAfterClosingAndShared() throws {
        let store = try PreviewData.makeStore()
        try store.perform(CloseMission())
        try store.perform(SetDebrief(MissionDebrief(participants: "Team A", wentWell: "Schnelle Sichtung", toImprove: "BR zu spät", actions: "Checkliste ergänzen – Max")))
        let debrief = try #require(store.state.mission.debrief)
        #expect(debrief.conductedAt != nil, "Zeitpunkt beim ersten Sichern")
        let text = MissionDebriefText.text(mission: store.state.mission, patients: store.state.patients, journal: store.state.journal, now: Date())
        #expect(text.contains("Nachbesprechung Einsatz"))
        #expect(text.contains("Was lief gut:\nSchnelle Sichtung"))
        #expect(text.contains("Meilensteine:"))
        #expect(!text.contains("Mustermann"), "ohne Patientennamen")
        try store.perform(SetDebrief(MissionDebrief()))
        #expect(store.state.mission.debrief == nil, "leeren entfernt")
    }
}
