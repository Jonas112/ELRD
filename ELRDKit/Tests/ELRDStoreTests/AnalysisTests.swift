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

    // MARK: 92 Eintreffen

    @Test func expectedArrivalAndArrived() throws {
        let store = try fixture.newMission()
        try store.perform(AddPlaceholder(type: .rtw))
        let placeholder = try #require(store.state.activeUnits.first { $0.isPlaceholder })
        try store.perform(SetExpectedArrival(unitID: placeholder.id, minutes: 10))
        let unit = try #require(store.state.activeUnits.first { $0.id == placeholder.id })
        #expect(unit.expectedArrival == fixture.clock.now.addingTimeInterval(600))
        #expect(unit.isAwaitingArrival)
        #expect(!unit.isArrivalOverdue(now: fixture.clock.now))
        #expect(unit.isArrivalOverdue(now: fixture.clock.now.addingTimeInterval(601)))

        try store.perform(MarkUnitArrived(unitID: placeholder.id))
        #expect(store.state.activeUnits.first { $0.id == placeholder.id }?.expectedArrival == nil)
        #expect(store.state.visibleLog.last?.message.hasSuffix("eingetroffen") == true)
    }

    // MARK: 93 Verbleibsliste

    @Test func whereaboutsShowDestinationAndSearch() throws {
        let store = try fixture.newMission()
        let transported = try store.perform(AddPatient(triage: .sk2, tagNumber: "PAK0042"))
        try store.perform(EditPatient(patientID: transported.id) {
            $0.firstName = "Jürgen"
            $0.lastName = "Müller"
            $0.estimatedAge = 54
        })
        let rtw = try unit(store, "RK 1", .rtw)
        try store.perform(AssignUnit(patientID: transported.id, unitID: rtw.id))
        try store.perform(SetDestination(patientID: transported.id, hospital: HospitalSnapshot(name: "Klinikum Nord")))
        try store.perform(StartTransport(patientID: transported.id))
        let released = try store.perform(AddPatient(triage: .sk3))
        try store.perform(ReleasePatient(patientID: released.id))
        _ = try store.perform(AddPatient(triage: .ungesichtet))

        let list = PatientWhereabouts.list(patients: store.state.patients, units: store.state.units, sections: store.state.sections, now: fixture.clock.now)
        #expect(list.map(\.place) == [.transported, .released, .onScene])
        let first = try #require(list.first)
        #expect(first.whereabouts == "Klinikum Nord")
        #expect(first.detail.hasPrefix("mit RK 1 ab "))
        #expect(first.birth == "ca. 54 J.")
        #expect(first.matches("mueller") == false, "ue ist kein ü")
        #expect(first.matches("müll jürg"))
        #expect(first.matches("MULLER"), "Akzente egal")
        #expect(first.matches("pak0042"))
        #expect(list[1].whereabouts == "Vor Ort entlassen")
    }

    // MARK: 95 Nachsichtung

    @Test func confirmTriageRecordsRetriage() throws {
        let store = try fixture.newMission()
        let patient = try store.perform(AddPatient(triage: .sk2))
        fixture.clock.advance(1200)
        try store.perform(ConfirmTriage(patientID: patient.id))
        let current = try #require(store.state.patients.first { $0.id == patient.id })
        #expect(current.lastTriagedAt == fixture.clock.now)
        #expect(current.triage == .sk2)
        #expect(current.triageHistory?.count == 2)
        #expect(store.state.visibleLog.last?.message.contains("Nachsichtung, bleibt") == true)
        let untriaged = try store.perform(AddPatient(triage: .ungesichtet))
        #expect(throws: CommandError.self) { try store.perform(ConfirmTriage(patientID: untriaged.id)) }

        // Sichtungshilfe mit gleicher Kategorie zählt als Nachsichtung.
        fixture.clock.advance(600)
        var session = TriageSession(algorithm: .mstart)
        for answer in [true, true, true, true, false, false, false] { session.answer(answer) }
        try store.perform(ApplyTriageSuggestion(patientID: patient.id, suggestion: try #require(session.suggestion)))
        #expect(store.state.patients.first { $0.id == patient.id }?.lastTriagedAt == fixture.clock.now)
    }

    // MARK: 97 ATMIST, 98 Voranmeldung, 99 Telefonbuch

    @Test func atmistAndPreannouncement() throws {
        let store = try fixture.newMission()
        let patient = try store.perform(AddPatient(triage: .sk1))
        try store.perform(EditPatient(patientID: patient.id) {
            $0.lastName = "Muster"
            $0.firstName = "Max"
            $0.estimatedAge = 45
            $0.gender = .maennlich
            $0.notes = "Beckenschlinge angelegt"
            $0.isIntubated = true
        })
        let rtw = try unit(store, "RK 1", .rtw)
        try store.perform(AssignUnit(patientID: patient.id, unitID: rtw.id))
        try store.perform(SetDestination(patientID: patient.id, hospital: HospitalSnapshot(name: "Klinikum Nord")))
        let second = try store.perform(AddPatient(triage: .sk2))
        try store.perform(SetDestination(patientID: second.id, hospital: HospitalSnapshot(name: "klinikum nord")))

        let current = try #require(store.state.patients.first { $0.id == patient.id })
        let text = ATMISTHandover.text(patient: current, mission: store.state.mission, units: store.state.units, now: fixture.clock.now)
        #expect(text.contains("Name: Muster, Max") || text.contains("Name: Max Muster"))
        #expect(text.contains("A – Alter: ca. 45 J., Männlich"))
        #expect(text.contains("T – Therapie: intubiert; Beckenschlinge angelegt; versorgt von RK 1"))
        #expect(text.contains("Ziel: Klinikum Nord"))

        let announcements = HospitalPreannouncement.all(mission: store.state.mission, patients: store.state.patients, units: store.state.units)
        #expect(announcements.count == 1, "Name ohne Groß/klein zusammengeführt")
        let first = try #require(announcements.first)
        #expect(first.patientCount == 2)
        #expect(first.text.contains("Patienten: 2 (1 × SK 1, 1 × SK 2)"))
        #expect(!first.text.contains("Muster"), "Voranmeldung ohne Namen")

        #expect(PhoneEntry.telURL("0971 / 123-45")?.absoluteString == "tel:097112345")
        #expect(PhoneEntry.telURL("–") == nil)
    }

    // MARK: 100 Statistik, 101 Personensuche

    @Test func statisticsSeparateExercisesAndSearchFindsPersons() throws {
        let real = try fixture.newMission()
        let patient = try real.perform(AddPatient(triage: .sk1))
        try real.perform(EditPatient(patientID: patient.id) { $0.lastName = "Huber"; $0.firstName = "Anna" })
        try real.perform(AddPatient(triage: .sk3))
        var request = NewMissionRequest(reason: "Übung", type: .brand, location: "Gelände")
        request.isExercise = true
        let clock = fixture.clock
        let exercise = try MissionStore.create(
            request,
            repository: fixture.repository,
            session: fixture.session(fixture.deviceA),
            clock: try DeviceClock(deviceID: fixture.deviceA.deviceID, repository: fixture.repository),
            now: { clock.now }
        )
        try exercise.perform(AddPatient(triage: .sk2))

        let summaries = try MissionOverview.load(from: fixture.repository)
        let stats = MissionStatistics(summaries: summaries, year: nil)
        #expect(stats.missions == 1)
        #expect(stats.exercises == 1)
        #expect(stats.patients == 2, "Übungspatienten zählen nicht")
        #expect(stats.triageCounts[.sk1] == 1)
        #expect(stats.byType.count == 1)

        let hits = try PersonSearch.search("hub", in: fixture.repository, now: fixture.clock.now)
        #expect(hits.count == 1)
        #expect(hits.first?.whereabouts.name.contains("Huber") == true)
        #expect(hits.first?.missionID == real.missionID)
        #expect(try PersonSearch.search("h", in: fixture.repository, now: fixture.clock.now).isEmpty, "mindestens 2 Zeichen")
    }

    // MARK: 102 Datenschutz, 104 Einsatzende-Prüfung

    @Test func closingCheckWarnsButAllowsClosing() throws {
        let store = try fixture.newMission()
        #expect(MissionClosingCheck.warnings(for: store.state, checklist: ChecklistTemplate(items: [])).isEmpty)
        try store.perform(AddPatient(triage: .ungesichtet))
        try store.perform(AddPlaceholder(type: .rtw))
        let warnings = MissionClosingCheck.warnings(for: store.state, checklist: .standard)
        #expect(warnings.contains("1 Patient ist noch nicht abtransportiert oder entlassen."))
        #expect(warnings.contains("1 Patient ist ungesichtet."))
        #expect(warnings.contains { $0.hasPrefix("1 angeforderte Einheit ohne Fahrzeug") })
        #expect(warnings.contains { $0.hasPrefix("Checkliste:") })
        try store.perform(CloseMission())
        #expect(store.state.mission.isClosed, "Beenden trotz Hinweisen")
    }

    @Test func anonymizationRemovesPersonalDataOnlyWhenClosed() throws {
        let store = try fixture.newMission()
        let patient = try store.perform(AddPatient(triage: .sk2, tagNumber: "PAK1"))
        let birth = Calendar.current.date(byAdding: .year, value: -40, to: fixture.clock.now)
        try store.perform(EditPatient(patientID: patient.id) {
            $0.firstName = "Eva"
            $0.lastName = "Berg"
            $0.birthDate = birth
            $0.identifyingFeatures = "rote Jacke"
            $0.notes = "wohnt Hauptstraße 1"
        })
        #expect(throws: CommandError.self) { try store.perform(AnonymizeMission(reason: "Test")) }
        try store.perform(CloseMission())
        let summaries = try MissionOverview.load(from: fixture.repository)
        #expect(AnonymizationPolicy.due(summaries, days: 30, now: fixture.clock.now).isEmpty, "gerade erst beendet")
        #expect(AnonymizationPolicy.due(summaries, days: 30, now: fixture.clock.now.addingTimeInterval(31 * 86_400)) == [store.missionID])
        #expect(AnonymizationPolicy.due(summaries, days: 0, now: fixture.clock.now.addingTimeInterval(400 * 86_400)).isEmpty, "aus")

        try store.perform(AnonymizeMission(reason: "Test"))
        let anonymized = try #require(store.state.patients.first { $0.id == patient.id })
        #expect(anonymized.fullName.isEmpty)
        #expect(anonymized.birthDate == nil)
        #expect(anonymized.estimatedAge == 40)
        #expect(anonymized.identifyingFeatures == nil)
        #expect(anonymized.notes.isEmpty)
        #expect(anonymized.tagNumber == "PAK1", "Karte bleibt für den Verbleib")
        #expect(anonymized.triage == .sk2)
        #expect(store.state.mission.anonymizedAt != nil)
        let after = try MissionOverview.load(from: fixture.repository)
        #expect(AnonymizationPolicy.due(after, days: 30, now: fixture.clock.now.addingTimeInterval(31 * 86_400)).isEmpty, "nur einmal")
    }
}
