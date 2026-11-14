import Foundation
import Testing
@testable import ELRDDomain

/// Schritt 140: Einsätze aus Alamos FE2 (Antworten des ELRD-Backends).
struct AlamosAlarmTests {
    /// So antwortet das Backend (aus einem echten Lauf übernommen, gekürzt).
    static let backendResponse = """
    {"serverTime":"2026-11-12T02:59:04.201Z","alarms":[
      {"id":"4b1e3a52-5f0e-4f3c-9a43-0c1d2e3f4a5b","externalId":"T261112-025903-854","revision":3,
       "receivedAt":"2026-11-12T02:59:03.158Z","updatedAt":"2026-11-12T02:59:05.236Z","closedAt":"2026-11-12T02:59:05.236Z",
       "sender":"ELRD-Debug","source":"mqtt","isTest":true,
       "data":{"externalId":"T261112-025903-854","keyword":"RD 4","keyword_description":"VU Reisebus, mehrere Verletzte (MANV)",
         "message":["Reisebus auf Seite, ca. 20 Insassen.","Zufahrt über AS Schweinfurt/Werneck."],
         "location":{"coordinate":[10.1003,49.9811],"street":"A 70","postalCode":"97440","city":"Werneck"},
         "units":[{"address":"ELRD"}],
         "vehicles":[{"id":"RKSWFT71-1","name":"RK SWFT 71/1","radioName":"RK SWFT 71/1","unitType":"RTW","station":"SWFT","alarmedTime":1794452343158},
                     {"id":"RKSWFT76-1","name":"RK SWFT 76/1","radioName":"RK SWFT 76/1","unitType":"NEF","station":"SWFT","alarmedTime":1794452343158}],
         "custom":{"elrdTest":"true"},"caller":{"name":"Testanrufer","contact":"0000 000000"},
         "patient":[{"name":"","remark":"eingeklemmt, Bein deformiert","patientNumber":"1"}]}},
      {"id":"9d7c6b5a-4e3f-4a2b-8c1d-0e9f8a7b6c5d","externalId":"4711","revision":2,
       "receivedAt":"2026-11-12T02:59:03.176Z","updatedAt":"2026-11-12T02:59:03.176Z",
       "sender":"FE2","source":"mqtt","isTest":false,
       "data":{"externalId":"4711","keyword":"RD 3","keyword_description":"Sturz","message":["Test"],"location":{"coordinate":[10.2,50.05],"city":"Schweinfurt"}}}
    ]}
    """

    @Test func decodesBackendResponse() throws {
        let list = try AlamosJSON.decoder().decode(AlamosAlarmList.self, from: Data(Self.backendResponse.utf8))
        #expect(list.alarms.count == 2)
        let bus = try #require(list.alarms.first)
        #expect(bus.externalId == "T261112-025903-854")
        #expect(bus.revision == 3)
        #expect(bus.isTest)
        #expect(bus.isClosed)
        #expect(bus.data.keyword == "RD 4")
        #expect(bus.data.title == "VU Reisebus, mehrere Verletzte (MANV)")
        #expect(bus.data.message.count == 2)
        #expect(bus.data.callsigns == ["RK SWFT 71/1", "RK SWFT 76/1"])
        #expect(bus.data.patients.first?.remark == "eingeklemmt, Bein deformiert")
        #expect(bus.data.patients.first?.name == nil, "leerer Name wird nil")
        #expect(bus.data.custom["elrdTest"] == "true")
        #expect(bus.data.vehicles.first?.alarmedAt != nil)
        // Reihenfolge: [Längengrad, Breitengrad]
        let coordinate = try #require(bus.data.location?.geoCoordinate)
        #expect(coordinate.latitude == 49.9811)
        #expect(coordinate.longitude == 10.1003)
        #expect(bus.data.location?.addressLine == "A 70, 97440 Werneck")
        #expect(bus.data.alarmstichwort == .rd4)
        #expect(list.alarms[1].closedAt == nil)
    }

    @Test func readsUnexpectedFieldsGenerously() throws {
        let json = """
        {"id":"4b1e3a52-5f0e-4f3c-9a43-0c1d2e3f4a5b","externalId":4711,"receivedAt":"2026-11-12T02:59:03Z",
         "data":{"externalId":4711,"keyword":"RD2","message":"Zeile 1\\nZeile 2",
           "location":{"coordinate":[0,0],"house":12},
           "vehicles":[{"radioName":"RK SWFT 71/1","alarmedTime":"1794452343158"},"Unsinn",{"name":"Christoph 18"}],
           "patient":{"kaputt":true},"custom":{"zahl":3,"wahr":true,"objekt":{"a":1}}}}
        """
        let alarm = try AlamosJSON.decoder().decode(AlamosAlarm.self, from: Data(json.utf8))
        #expect(alarm.externalId == "4711")
        #expect(alarm.revision == 1)
        #expect(alarm.updatedAt == alarm.receivedAt)
        #expect(alarm.data.message == ["Zeile 1", "Zeile 2"])
        #expect(alarm.data.location?.house == "12")
        #expect(alarm.data.location?.geoCoordinate == nil, "0/0 gilt als fehlend")
        #expect(alarm.data.vehicles.count == 2, "unlesbare Einträge übersprungen")
        #expect(alarm.data.vehicles[0].alarmedTime == 1_794_452_343_158)
        #expect(alarm.data.patients.isEmpty)
        #expect(alarm.data.custom == ["zahl": "3", "wahr": "true"])
        #expect(alarm.data.alarmstichwort == .rd2, "RD2 ohne Leerzeichen")
    }

    @Test func titleFallsBack() {
        #expect(AlamosAlarmData(keyword: "RD 1").title == "RD 1")
        #expect(AlamosAlarmData(message: ["Text"]).title == "Text")
        #expect(AlamosAlarmData().title == "Einsatz ohne Stichwort")
        #expect(AlamosAlarmData(keyword: "B 3").alarmstichwort == nil)
    }

    @Test func addressLine() {
        let full = AlamosLocation(building: "Pflegeheim St. Anna", street: "Rügshöfer Straße", house: "20", crossing: "B 286", additional: "Hintereingang", postalCode: "97447", city: "Gerolzhofen")
        #expect(full.addressLine == "Pflegeheim St. Anna, Rügshöfer Straße 20, Kreuzung B 286, 97447 Gerolzhofen, Hintereingang")
        #expect(AlamosLocation().addressLine.isEmpty)
    }

    @Test func guessesUnitTypes() {
        #expect(AlamosVehicle(unitType: "NEF", radioName: "X").guessedUnitType == .nef)
        #expect(AlamosVehicle(unitType: "KTW-KatS").guessedUnitType == .ktwKatS)
        #expect(AlamosVehicle(radioName: "RK SWFT 71/1").guessedUnitType == .rtw)
        #expect(AlamosVehicle(radioName: "RK SWFT 72/3").guessedUnitType == .ktw)
        #expect(AlamosVehicle(radioName: "JOH SWFT 76/1").guessedUnitType == .nef)
        #expect(AlamosVehicle(name: "Christoph 18").guessedUnitType == .rth)
        #expect(AlamosVehicle(radioName: "FL SW 40/1").guessedUnitType == .sonstiges)
    }

    @Test func journalTextHasEssentials() {
        let data = AlamosAlarmData(
            externalId: "4711", keyword: "RD 2", keywordDescription: "VU",
            message: ["Pkw gegen Baum"],
            location: AlamosLocation(street: "Markt", postalCode: "97421", city: "Schweinfurt"),
            patients: [AlamosPatient(remark: "eingeklemmt")],
            vehicles: [AlamosVehicle(radioName: "RK SWFT 71/1"), AlamosVehicle(radioName: "rk swft 71/1")]
        )
        let text = data.journalText
        #expect(text.contains("Einsatznummer: 4711"))
        #expect(text.contains("Stichwort: RD 2 – VU"))
        #expect(text.contains("Einsatzort: Markt, 97421 Schweinfurt"))
        #expect(text.contains("Pkw gegen Baum"))
        #expect(text.contains("Alarmierte Fahrzeuge: RK SWFT 71/1\n"), "Doppelte ohne Rücksicht auf Groß/klein entfernt")
        #expect(text.contains("Gemeldete Patienten: 1"))
    }

    /// Schritt 143: Unterschiede zwischen zwei Ständen.
    @Test func changesSinceSnapshot() {
        let old = AlamosAlarmData(
            keyword: "RD 3",
            message: ["Bus", " "],
            location: AlamosLocation(street: "A 70", city: "Werneck"),
            patients: [AlamosPatient(name: "Anna Alt", patientNumber: "1"), AlamosPatient(remark: "gehfähig")],
            vehicles: [AlamosVehicle(radioName: "RK SWFT 71/1")]
        )
        let snapshot = AlarmSnapshot(old)
        #expect(snapshot.patientKeys == ["1", "#1"])
        #expect(snapshot.message == ["Bus"])
        #expect(snapshot.vehicleKeys == ["rk swft 71/1"])
        #expect(old.changes(since: snapshot).isEmpty)

        var changed = old
        changed.keyword = "RD 4"
        changed.keywordDescription = "MANV"
        changed.message.append("Zweiter Bus")
        changed.vehicles.append(AlamosVehicle(radioName: "rk swft 71/1"))
        changed.vehicles.append(AlamosVehicle(radioName: "RK SWFT 76/1"))
        changed.patients.append(AlamosPatient(name: "Bernd Neu", remark: "Schock"))
        changed.location?.city = "Schweinfurt"
        let changes = changed.changes(since: snapshot)
        #expect(changes.keyword == "RD 3 → RD 4 – MANV")
        #expect(changes.callsigns == ["RK SWFT 76/1"])
        #expect(changes.patients.map(\.name) == ["Bernd Neu"])
        #expect(changes.messageLines == ["Zweiter Bus"])
        #expect(changes.address == "A 70, Schweinfurt")
        #expect(changes.patientKeys == ["#2"])
        #expect(changes.summary == ["Stichwort RD 3 → RD 4 – MANV", "+1 Fahrzeug nachalarmiert: RK SWFT 76/1", "+1 Patient gemeldet", "Alarmtext ergänzt (1 Zeile)", "Einsatzort: A 70, Schweinfurt"])
        #expect(changes.entries.map(\.kind) == [.keyword, .vehicles, .patients, .message, .address])

        // Weggefallenes zählt nicht.
        var fewer = old
        fewer.vehicles = []
        fewer.patients = []
        #expect(fewer.changes(since: snapshot).isEmpty)
    }

    /// Schritt 144: ältere Einstellungen ohne „pushEnabled“ → Push an.
    @Test func settingsPushDefault() throws {
        let old = try JSONDecoder().decode(AlamosSettings.self, from: Data(#"{"isEnabled":true,"backendURL":"http://192.168.1.2:8080"}"#.utf8))
        #expect(old.pushEnabled)
        var settings = AlamosSettings()
        settings.pushEnabled = false
        let roundTrip = try JSONDecoder().decode(AlamosSettings.self, from: JSONEncoder().encode(settings))
        #expect(!roundTrip.pushEnabled)
    }

    @Test func settingsNormalizeURL() {
        #expect(AlamosSettings.normalize("elrd.example.de/")?.absoluteString == "https://elrd.example.de")
        #expect(AlamosSettings.normalize(" http://192.168.1.20:8080 ")?.absoluteString == "http://192.168.1.20:8080")
        // Ohne Schema: IP, localhost, .local und Namen ohne Punkt → http (Backend im eigenen Netz), sonst https.
        #expect(AlamosSettings.normalize("100.101.102.103:8080")?.absoluteString == "http://100.101.102.103:8080")
        #expect(AlamosSettings.normalize("localhost:8080")?.absoluteString == "http://localhost:8080")
        #expect(AlamosSettings.normalize("macbook-jonas:8080")?.absoluteString == "http://macbook-jonas:8080")
        #expect(AlamosSettings.normalize("Jonas-MacBook.local:8080/")?.absoluteString == "http://Jonas-MacBook.local:8080")
        #expect(AlamosSettings.normalize("https://100.101.102.103:8443")?.absoluteString == "https://100.101.102.103:8443")
        #expect(AlamosSettings.normalize("elrd.example.de:8080")?.absoluteString == "https://elrd.example.de:8080")
        #expect(AlamosSettings.normalize("1.2.3")?.absoluteString == "https://1.2.3")
        #expect(AlamosSettings.normalize("") == nil)
        #expect(AlamosSettings.normalize("https://") == nil)
    }

    @Test func olderSettingsDocumentsStayReadable() throws {
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"organisationName":"BRK"}"#.utf8))
        #expect(old.alamos == AlamosSettings())
        var settings = AppSettings()
        settings.alamos.isEnabled = true
        settings.alamos.backendURL = "https://elrd.example.de"
        settings.alamos.pollSeconds = 60
        let roundTrip = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(roundTrip.alamos == settings.alamos)
        // Neuere Felder fehlen in älteren Alamos-Einstellungen → Standard.
        let partial = try JSONDecoder().decode(AlamosSettings.self, from: Data(#"{"isEnabled":true}"#.utf8))
        #expect(partial.isEnabled && partial.pollSeconds == 30 && partial.importsPatients)
    }

    @Test func missionWithoutReferenceStaysReadable() throws {
        let reference = ExternalAlarmReference(externalID: "4711", revision: 2, importedAt: Date(timeIntervalSince1970: 1_000))
        let data = try JSONEncoder().encode(reference)
        #expect(try JSONDecoder().decode(ExternalAlarmReference.self, from: data) == reference)
        #expect(reference.source == "Alamos FE2")
    }

    @Test func parsesDatesWithAndWithoutFraction() {
        #expect(AlamosJSON.parseDate("2026-11-12T02:59:04.201Z") != nil)
        #expect(AlamosJSON.parseDate("2026-11-12T03:59:04+01:00") != nil)
        #expect(AlamosJSON.parseDate("gestern") == nil)
        let date = Date(timeIntervalSince1970: 1_794_452_344.5)
        #expect(AlamosJSON.format(date) == "2026-11-12T02:59:04.500Z")
    }
}
