import Foundation
import Testing
@testable import ELRDDomain
@testable import ELRDStore

@Suite("Einsatzanalyse (Schritte 67–76)")
@MainActor
struct AnalysisTests {
    let fixture: StoreFixture

    init() throws {
        fixture = try StoreFixture()
    }

    private func unit(_ store: MissionStore, _ callsign: String, _ type: UnitType) throws -> MissionUnit {
        try store.perform(AddTemporaryUnit(callsign: callsign, type: type))
    }

    // MARK: 68 Nachforderung

    @Test func sk1NeedsRTWAndNEFOrHelicopter() throws {
        let store = try fixture.newMission()
        try store.perform(AddPatient(triage: .sk1))
        try store.perform(AddPatient(triage: .sk1))
        _ = try unit(store, "RK 1", .rtw)
        _ = try unit(store, "NEF 1", .nef)
        _ = try unit(store, "Christoph 1", .rth)
        let demand = ResourceDemand.calculate(store.state)
        #expect(demand.patients[.sk1] == 2)
        #expect(!demand.hasShortfall, "einer mit RTW + NEF, einer mit RTH")
    }

    @Test func shortfallIsCountedPerType() throws {
        let store = try fixture.newMission()
        try store.perform(AddPatient(triage: .sk1))
        try store.perform(AddPatient(triage: .sk2))
        try store.perform(AddPatient(triage: .sk3))
        try store.perform(AddPatient(triage: .sk3))
        _ = try unit(store, "RK 1", .rtw)
        let demand = ResourceDemand.calculate(store.state)
        // SK1 nimmt den RTW, NEF fehlt; SK2 braucht RTW; SK3 zwei KTW.
        #expect(demand.missing[.nef] == 1)
        #expect(demand.missing[.rtw] == 1)
        #expect(demand.missing[.ktw] == 2)
        #expect(demand.missingSummary == "1 RTW, 1 NEF, 2 KTW")
        #expect(ResourceDemand.summary(demand.emergencyMissing) == "1 RTW, 2 KTW", "in großer Not SK 1 ohne NEF")
    }

    @Test func spareRTWServesSK3AndTransportingUnitsDoNotCount() throws {
        let store = try fixture.newMission()
        let sk3 = try store.perform(AddPatient(triage: .sk3))
        let busy = try store.perform(AddPatient(triage: .sk2))
        let rtw1 = try unit(store, "RK 1", .rtw)
        _ = try unit(store, "RK 2", .rtw)
        try store.perform(AssignUnit(patientID: busy.id, unitID: rtw1.id))
        try store.perform(StartTransport(patientID: busy.id))
        let demand = ResourceDemand.calculate(store.state)
        #expect(demand.available[.rtw] == 1)
        #expect(!demand.hasShortfall, "übriger RTW übernimmt SK 3 \(sk3.number)")
    }

    @Test func requestingCreatesPlaceholdersAndJournalEntry() throws {
        let store = try fixture.newMission()
        try store.perform(AddPatient(triage: .sk2))
        try store.perform(AddPatient(triage: .sk2))
        let demand = ResourceDemand.calculate(store.state)
        try store.perform(RequestPlaceholders(demand.missing))
        #expect(store.state.activeUnits.filter(\.isPlaceholder).count == 2)
        #expect(!ResourceDemand.calculate(store.state).hasShortfall, "Platzhalter zählen als angefordert")
        #expect(store.state.journal.contains { $0.text.contains("Nachforderung an ILS: 2 RTW") })
    }

    // MARK: 67 Lagemeldung, 69 Erinnerung

    @Test func situationReportSummarisesAndIsJournaled() throws {
        let store = try fixture.newMission()
        try store.perform(AddPatient(triage: .sk1))
        try store.perform(AddPatient(triage: .sk3))
        _ = try unit(store, "RK 1", .rtw)
        let text = SituationReport.text(for: store.state, now: fixture.clock.now)
        #expect(text.contains("Patienten: 2 gesamt – SK 1 1, SK 3 1"))
        #expect(text.contains("Nachforderung: 1 NEF, 1 KTW"))

        try store.perform(AddSituationReport(text: text, situationNote: "Pkw gegen Bus", hazards: "auslaufender Kraftstoff"))
        #expect(store.state.mission.hazards == "auslaufender Kraftstoff")
        #expect(store.state.lastSituationReportAt == fixture.clock.now)
        let again = SituationReport.text(for: store.state, now: fixture.clock.now)
        #expect(again.contains("Lage: Pkw gegen Bus"))
        #expect(again.contains("Gefahren: auslaufender Kraftstoff"))
    }

    // MARK: 70 Transport-Board

    @Test func boardOrdersBySeverityThenWaitingTime() throws {
        let store = try fixture.newMission()
        let first = try store.perform(AddPatient(triage: .sk3))
        fixture.clock.advance(60)
        let urgent = try store.perform(AddPatient(triage: .sk1))
        fixture.clock.advance(60)
        let assigned = try store.perform(AddPatient(triage: .sk2))
        let rtw = try unit(store, "RK 1", .rtw)
        try store.perform(AssignUnit(patientID: assigned.id, unitID: rtw.id))
        _ = try store.perform(AddPatient(triage: .unverletzt))

        let columns = TransportBoard.columns(store.state)
        #expect(columns[.waiting]?.map(\.id) == [urgent.id, first.id])
        #expect(columns[.assigned]?.map(\.id) == [assigned.id])
        try store.perform(StartTransport(patientID: assigned.id))
        #expect(TransportBoard.columns(store.state)[.departed]?.map(\.id) == [assigned.id])
    }

    // MARK: 71 Kliniken

    @Test func hospitalQuotaDetectsOverload() throws {
        let store = try fixture.newMission()
        let clinic = HospitalSnapshot(name: "Klinikum Nord")
        try store.perform(SetHospitalQuota(HospitalQuota(hospitalName: "klinikum nord", sk1: 1, sk2: 2)))
        for _ in 0..<2 {
            let patient = try store.perform(AddPatient(triage: .sk1))
            try store.perform(SetDestination(patientID: patient.id, hospital: clinic))
        }
        let load = try #require(HospitalDistribution.load(of: clinic, in: store.state))
        #expect(load.remaining(.sk1) == -1)
        #expect(load.remaining(.sk2) == 2)
        #expect(load.overloadedTriages == [.sk1])
        #expect(HospitalDistribution.loads(store.state).count == 1, "Name ohne Groß/klein zusammengeführt")

        try store.perform(SetHospitalQuota(HospitalQuota(hospitalName: "Klinikum Nord")))
        #expect(store.state.mission.hospitalQuotas?.count == 1, "Klinik bleibt ohne Grenzen in der Liste")
        #expect(HospitalDistribution.load(of: clinic, in: store.state)?.overloadedTriages == [])
        try store.perform(RemoveHospitalQuota(quotaID: HospitalQuota.key("Klinikum Nord")))
        #expect(store.state.mission.hospitalQuotas == nil)
    }

    // MARK: 72 Anhängekarte

    @Test func tagNumberIsUniqueAndFindable() throws {
        let store = try fixture.newMission()
        let patient = try store.perform(AddPatient(triage: .sk2, tagNumber: " pak 0042 "))
        #expect(patient.tagNumber == "PAK0042")
        #expect(store.state.patient(withTag: "PAK 0042")?.id == patient.id)
        #expect(throws: CommandError.self) { try store.perform(AddPatient(tagNumber: "PAK0042")) }
        let other = try store.perform(AddPatient(triage: .sk3))
        #expect(throws: CommandError.self) { try store.perform(SetPatientTag(patientID: other.id, tagNumber: "pak0042")) }
    }

    // MARK: 73 Führung

    @Test func leadershipAndForces() throws {
        let store = try fixture.newMission()
        try store.perform(SetLeadershipPosition(LeadershipPosition(role: .lna, name: "Dr. Weber", callsign: "LNA 1", radioChannel: "TMO 312")))
        #expect(store.state.mission.position(.lna).callsign == "LNA 1")
        try store.perform(SetLeadershipPosition(LeadershipPosition(role: .lna)))
        #expect(store.state.mission.leadership == nil)

        let section = try #require(store.state.activeSections.first)
        try store.perform(SetSectionLeader(sectionID: section.id, name: "Meier", callsign: "RK 10/1", radioChannel: "TMO 313"))
        #expect(store.state.activeSections.first?.radioChannel == "TMO 313")

        _ = try unit(store, "RK 1", .rtw)
        try store.perform(AddPlaceholder(type: .ktw))
        let forces = ForceOverview(state: store.state)
        #expect(forces.unitCount == 1)
        #expect(forces.placeholderCount == 1)
    }

    // MARK: 75 Übergabe, 76 Checkliste

    @Test func checklistIsConflictFreeAndHandoverRecords() throws {
        let store = try fixture.newMission()
        let item = ChecklistTemplate.standard.items[0]
        try store.perform(CheckChecklistItem(item))
        try store.perform(CheckChecklistItem(item))
        #expect(store.state.journal.active.filter { $0.category == .checklist }.count == 1, "doppelt abhaken bleibt ein Eintrag")
        #expect(store.state.checkedItems[item.id] != nil)
        try store.perform(UncheckChecklistItem(item.id))
        #expect(store.state.checkedItems[item.id] == nil)

        let report = HandoverReport.text(for: store.state, checklist: .standard, now: fixture.clock.now)
        #expect(report.contains("Checkliste offen"))
        let newLead = UserID()
        try store.perform(HandOverMission(newCommanderID: newLead, newCommanderName: "Max Muster", report: report))
        #expect(store.state.mission.commanderID == newLead)
        #expect(store.state.mission.position(.einsatzleiter).name == "Max Muster")
        #expect(store.state.journal.contains { $0.category == .handover })
    }

    @Test func checklistTemplateKeepsIDsWhenEdited() {
        let template = ChecklistTemplate.standard
        let edited = template.updated(fromLines: "Neuer Punkt\n" + template.items[1].title + "\n\n")
        #expect(edited.items.count == 2)
        #expect(edited.items[1].id == template.items[1].id)
    }

    // MARK: 78 Einsatzarten und Checklisten

    @Test func missionTypesStayCompatibleAndCustomTypesWork() throws {
        let data = try JSONEncoder().encode(MissionType.verkehrsunfall)
        #expect(String(decoding: data, as: UTF8.self) == "\"VU\"", "gespeichert wie bisher")
        #expect(try JSONDecoder().decode(MissionType.self, from: Data("\"Brand\"".utf8)) == .brand)
        let custom = try #require(MissionType(customName: " Großveranstaltung "))
        #expect(custom.displayName == "Großveranstaltung")
        #expect(!custom.isBuiltIn)
        #expect(MissionType(customName: "verkehrsunfall") == .verkehrsunfall, "Name einer mitgelieferten Art")
        #expect(MissionType(legacyValue: "Großveranstaltung") == nil)
    }

    @Test func checklistFollowsMissionType() {
        var settings = AppSettings()
        #expect(settings.checklist(for: .brand) == ChecklistTemplate.standard, "ohne Einstellung: Standard")
        let fire = NamedChecklist(id: "brand", name: "Brand", items: [ChecklistItem(id: "atemschutz", title: "Atemschutz-Sammelplatz")])
        let none = NamedChecklist(id: "ohne", name: "Ohne Art", items: [ChecklistItem(id: "x", title: "Lage klären")])
        settings.checklists = settings.effectiveChecklists + [fire, none]
        settings.missionTypes = [MissionTypeSetting(type: .brand, checklistID: "brand"), MissionTypeSetting(type: .verkehrsunfall)]
        settings.defaultChecklistID = "ohne"
        #expect(settings.checklist(for: .brand).items.map(\.id) == ["atemschutz"])
        #expect(settings.checklist(for: .verkehrsunfall).items.map(\.id) == ["x"], "Art ohne eigene Liste: Standard für ohne Einsatzart")
        #expect(settings.checklist(for: nil).items.map(\.id) == ["x"])
        #expect(settings.missionTypeChoices(including: .gefahrgut) == [.brand, .verkehrsunfall, .gefahrgut], "eigene Art des Einsatzes bleibt wählbar")

        let restored = try? JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(restored == settings)
    }

    // MARK: 86 Verlauf und Kennzahlen

    @Test func metricsFollowTriageAndTransport() throws {
        let store = try fixture.newMission()
        let start = store.state.mission.startedAt
        fixture.clock.advance(120)
        let first = try store.perform(AddPatient(triage: .ungesichtet))
        fixture.clock.advance(180)
        try store.perform(SetTriage(patientID: first.id, triage: .sk2))
        let second = try store.perform(AddPatient(triage: .sk1))
        var metrics = MissionMetrics(mission: store.state.mission, patients: store.state.patients, journal: store.state.journal, now: fixture.clock.now)
        #expect(metrics.minutesFromStart(metrics.firstPatientAt) == 2)
        #expect(metrics.minutesFromStart(metrics.firstTriageAt) == 5)
        #expect(metrics.minutesFromStart(metrics.allTriagedAt) == 5)
        #expect(metrics.lastPatientGoneAt == nil)
        #expect(store.state.patients.first { $0.id == first.id }?.triageHistory?.map(\.triage) == [.ungesichtet, .sk2])

        // SK-Verlauf: erst 1 ungesichtet, dann SK 2 + SK 1.
        #expect(metrics.triageSeries.first?.count(.ungesichtet) == 1)
        #expect(metrics.triageSeries.last?.count(.sk2) == 1)
        #expect(metrics.triageSeries.last?.count(.sk1) == 1)
        #expect(metrics.triageSeries.last?.count(.ungesichtet) == 0)

        let rtw = try unit(store, "RK 1", .rtw)
        try store.perform(AssignUnit(patientID: second.id, unitID: rtw.id))
        fixture.clock.advance(600)
        try store.perform(StartTransport(patientID: second.id))
        try store.perform(ReleasePatient(patientID: first.id))
        metrics = MissionMetrics(mission: store.state.mission, patients: store.state.patients, journal: store.state.journal, now: fixture.clock.now)
        #expect(metrics.minutesFromStart(metrics.firstTransportAt) == 15)
        #expect(metrics.waits[.sk1] == MissionMetrics.Wait(count: 1, averageMinutes: 10, maximumMinutes: 10))
        #expect(metrics.lastPatientGoneAt != nil)
        #expect(metrics.milestones.first?.kind == .start)
        #expect(metrics.milestones.map(\.kind).contains(.lastPatientGone))
        #expect(metrics.milestones.map(\.date) == metrics.milestones.map(\.date).sorted())
        _ = start
    }

    @Test func olderPatientsWithoutHistoryStillCount() throws {
        let store = try fixture.newMission()
        try store.perform(AddPatient(triage: .sk3))
        var patient = try #require(store.state.patients.first)
        patient.triageHistory = nil
        #expect(patient.firstTriagedAt == patient.metadata.createdAt, "ohne Verlauf: seit der Anlage")
        #expect(patient.triage(at: patient.metadata.createdAt.addingTimeInterval(-1)) == nil)
        patient.recordTriage(.sk2, at: patient.metadata.createdAt.addingTimeInterval(60))
        #expect(patient.triageHistory?.map(\.triage) == [.sk3, .sk2])
    }

    // MARK: 87 Geführte Sichtung

    @Test func guidedTriageIsAppliedAndLogged() throws {
        let store = try fixture.newMission()
        let patient = try store.perform(AddPatient(triage: .ungesichtet))
        var session = TriageSession(algorithm: .mstart)
        session.answer(true)
        session.answer(false)
        let suggestion = try #require(session.suggestion)
        try store.perform(ApplyTriageSuggestion(patientID: patient.id, suggestion: suggestion))
        #expect(store.state.patients.first { $0.id == patient.id }?.triage == .sk1)
        #expect(store.state.logEntries.contains { $0.message.contains("Sichtung nach mSTaRT: Atmung ja, AF 10–30 nein → SK 1") })
    }

    // MARK: 88 Übung

    @Test func exerciseScenarioIsPlayedAndEvaluated() throws {
        let scenario = try #require(ExerciseScenario.scenario(id: "bus"))
        var request = NewMissionRequest(reason: scenario.reason, type: scenario.type, location: scenario.location)
        request.scenario = scenario
        let clock = fixture.clock
        let store = try MissionStore.create(
            request,
            repository: fixture.repository,
            session: fixture.session(fixture.deviceA),
            clock: try DeviceClock(deviceID: fixture.deviceA.deviceID, repository: fixture.repository),
            now: { clock.now }
        )
        #expect(store.state.mission.isExerciseMission, "Lage macht den Einsatz zur Übung")
        let patients = Patient.sortedByNumber(store.state.patients.active)
        #expect(patients.count == scenario.patients.count)
        #expect(patients.allSatisfy { $0.triage == .ungesichtet && $0.expectedTriage != nil && !$0.notes.isEmpty })
        #expect(store.state.journal.contains { $0.text.contains("Übungslage „Reisebus umgestürzt“") })

        var evaluation = try #require(ExerciseEvaluation(patients: store.state.patients))
        #expect(evaluation.notTriaged == scenario.patients.count)
        // Erste richtig, zweite falsch sichten.
        try store.perform(SetTriage(patientID: patients[0].id, triage: try #require(patients[0].expectedTriage)))
        try store.perform(SetTriage(patientID: patients[1].id, triage: .sk3))
        evaluation = try #require(ExerciseEvaluation(patients: store.state.patients))
        #expect(evaluation.matching == 1)
        #expect(evaluation.deviations.count == 1)
        #expect(evaluation.summary == "1 von 12 wie erwartet · 1 abweichend · 10 noch ungesichtet")
        #expect(MissionSummary(mission: store.state.mission, patients: store.state.patients).isExercise)
    }

    @Test func realMissionsAreNoExercise() throws {
        let store = try fixture.newMission()
        #expect(!store.state.mission.isExerciseMission)
        #expect(ExerciseEvaluation(patients: store.state.patients) == nil)
        for scenario in ExerciseScenario.all {
            #expect(!scenario.patients.isEmpty)
            #expect(Set(ExerciseScenario.all.map(\.id)).count == ExerciseScenario.all.count)
        }
    }
}
