import Foundation
import Observation
import UserNotifications
import ELRDDomain
import ELRDAuth

/// Eingang für Einsätze aus Alamos FE2 (Schritt 140).
///
/// Fragt das ELRD-Backend regelmäßig ab, solange die App im Vordergrund ist, und
/// merkt sich, welche Einsätze bzw. Stände neu sind. Der App-Schlüssel liegt in der
/// Keychain, alles andere in den Geräteeinstellungen (`AppSettings.alamos`).
@MainActor
@Observable
final class AlamosInbox {
    static let keychainKey = "alamos.apiKey"

    /// Alle Einsätze des Backends, neueste Änderung zuerst.
    private(set) var alarms: [AlamosAlarm] = []
    private(set) var lastSuccess: Date?
    private(set) var lastError: String?
    private(set) var isRefreshing = false
    /// Neue Einsätze bzw. neue Stände seit dem letzten Ansehen.
    private(set) var unseen: Set<UUID> = []
    /// Schritt 144: Stand der Anmeldung für Push-Mitteilungen.
    private(set) var push: PushState = .off
    /// Wird bei einem neuen Einsatz aufgerufen (Hinweis, Haptik).
    @ObservationIgnored var onNewAlarm: ((AlamosAlarm) -> Void)?
    /// Schritt 143: Wird bei einem neuen Stand eines bekannten Einsatzes aufgerufen
    /// (Kurzfassung der Änderungen ohne Patientennamen).
    @ObservationIgnored var onChangedAlarm: ((AlamosAlarm, [String]) -> Void)?

    @ObservationIgnored private let settingsStore: AppSettingsStore
    @ObservationIgnored private let secureStore: any SecureStore
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var knownRevisions: [UUID: Int] = [:]
    @ObservationIgnored private var hasLoaded = false
    /// Angemeldet als (Kennzeichen, Adresse, Schlüssel) – nur im Arbeitsspeicher.
    @ObservationIgnored private var registeredDevice: DeviceRegistration?
    @ObservationIgnored private var pushTask: Task<Void, Never>?
    /// Beispieldaten: keine Netzabfragen.
    let isDemo: Bool

    init(settings: AppSettingsStore, secureStore: any SecureStore, isDemo: Bool = false, now: @escaping () -> Date = Date.init) {
        self.settingsStore = settings
        self.secureStore = secureStore
        self.isDemo = isDemo
        self.now = now
    }

    var settings: AlamosSettings { settingsStore.settings.alamos }

    var isEnabled: Bool { settings.isEnabled }

    // MARK: App-Schlüssel (Keychain)

    var hasAPIKey: Bool { !(storedAPIKey ?? "").isEmpty }

    var storedAPIKey: String? { (try? secureStore.string(for: Self.keychainKey)) ?? nil }

    func setAPIKey(_ key: String?) throws {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        try secureStore.set((trimmed?.isEmpty ?? true) ? nil : trimmed, for: Self.keychainKey)
        updatePushRegistration()
    }

    /// Einstellungen ändern (nur über diesen Weg, damit der Abruf neu startet).
    func updateSettings(_ change: (inout AlamosSettings) -> Void) throws {
        try settingsStore.update { change(&$0.alamos) }
        restart()
        updatePushRegistration()
    }

    // MARK: Push-Mitteilungen (Schritt 144)

    enum PushState: Equatable {
        /// Abruf oder Push ausgeschaltet, Beispieldaten.
        case off
        /// iPadOS hat noch kein Kennzeichen geliefert.
        case waitingForDevice
        case registering
        /// Angemeldet; `backendSends`: Backend hat Push eingerichtet.
        case registered(backendSends: Bool)
        case failed(String)
    }

    struct DeviceRegistration: Equatable {
        let token: String
        let url: URL
        let key: String
    }

    /// Gewünschte Anmeldung nach den aktuellen Einstellungen (`nil`: keine).
    private var wantedRegistration: DeviceRegistration? {
        guard isEnabled, settings.pushEnabled, !isDemo, let token = PushToken.shared.hex,
              let url = settings.normalizedURL, let key = storedAPIKey, !key.isEmpty else { return nil }
        return DeviceRegistration(token: token, url: url, key: key)
    }

    /// Beim Backend an- bzw. abmelden, wenn sich Kennzeichen, Adresse, Schlüssel oder
    /// Einstellungen geändert haben. Nacheinander, damit Abmelden nie das neue Anmelden überholt.
    func updatePushRegistration() {
        let wanted = wantedRegistration
        if wanted == nil {
            push = isDemo || !isEnabled || !settings.pushEnabled ? .off : (PushToken.shared.hex == nil ? .waitingForDevice : push)
        }
        guard wanted != registeredDevice else { return }
        let previous = registeredDevice
        registeredDevice = wanted
        let earlier = pushTask
        pushTask = Task { [weak self] in
            await earlier?.value
            if let previous {
                try? await AlamosBackendClient(baseURL: previous.url, apiKey: previous.key).unregisterDevice(token: previous.token)
            }
            guard let wanted else { return }
            self?.push = .registering
            do {
                let result = try await AlamosBackendClient(baseURL: wanted.url, apiKey: wanted.key)
                    .registerDevice(token: wanted.token, environment: PushToken.environment)
                self?.push = .registered(backendSends: result.pushEnabled)
            } catch {
                guard let self else { return }
                self.push = .failed(ErrorText.message(for: error))
                // Beim nächsten Abruf erneut versuchen.
                if self.registeredDevice == wanted { self.registeredDevice = nil }
            }
        }
    }

    /// Mitteilungen erlauben (einmalige Abfrage von iPadOS).
    private func requestNotificationPermission() {
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        }
    }

    private func makeClient(url: URL? = nil, key: String? = nil) throws -> AlamosBackendClient {
        guard let base = url ?? settings.normalizedURL, let key = key ?? storedAPIKey, !key.isEmpty else {
            throw AlamosClientError.notConfigured
        }
        return AlamosBackendClient(baseURL: base, apiKey: key)
    }

    // MARK: Anzeige

    /// Einsätze für die Liste: geschlossene und Tests je nach Einstellung.
    var visibleAlarms: [AlamosAlarm] {
        alarms.filter { alarm in
            (settings.showsClosed || !alarm.isClosed) && (settings.showsTests || !alarm.isTest)
        }
    }

    func isUnseen(_ alarm: AlamosAlarm) -> Bool { unseen.contains(alarm.id) }

    func markSeen(_ alarm: AlamosAlarm) {
        unseen.remove(alarm.id)
    }

    // MARK: Abfrage

    /// Startet die regelmäßige Abfrage (nur im Vordergrund aufrufen).
    func start() {
        guard pollTask == nil, isEnabled, !isDemo else { return }
        requestNotificationPermission()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let seconds = max(10, self.settings.pollSeconds)
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func restart() {
        stop()
        if isEnabled {
            start()
        } else {
            alarms = []
            unseen = []
            lastError = nil
        }
    }

    /// Einmal abfragen (auch per „Aktualisieren“).
    func refresh() async {
        guard isEnabled, !isDemo, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let list = try await makeClient().alarms()
            apply(list.alarms)
            lastSuccess = now()
            lastError = nil
            if registeredDevice == nil { updatePushRegistration() }
        } catch is CancellationError {
            return
        } catch {
            lastError = ErrorText.message(for: error)
        }
    }

    /// Verbindung mit (noch nicht gespeicherten) Angaben prüfen.
    func testConnection(url text: String, key: String?) async throws -> AlamosPing {
        guard let url = AlamosSettings.normalize(text) else { throw AlamosClientError.invalidURL }
        return try await makeClient(url: url, key: key ?? storedAPIKey).ping()
    }

    /// Übernimmt eine neue Liste und erkennt neue Einsätze bzw. Stände.
    func apply(_ incoming: [AlamosAlarm]) {
        let sorted = incoming.sorted { $0.updatedAt > $1.updatedAt }
        let previous = Dictionary(alarms.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var fresh: [AlamosAlarm] = []
        var changed: [(AlamosAlarm, [String])] = []
        for alarm in sorted {
            let known = knownRevisions[alarm.id]
            if known == nil || known! < alarm.revision {
                // Beim ersten Abruf nur Einsätze der letzten 15 Minuten als neu markieren.
                let isRecent = now().timeIntervalSince(alarm.updatedAt) < 15 * 60
                if hasLoaded || isRecent, !alarm.isClosed { unseen.insert(alarm.id) }
                if hasLoaded, known == nil, !alarm.isClosed { fresh.append(alarm) }
                if hasLoaded, known != nil, let old = previous[alarm.id] {
                    let summary = Self.changeSummary(from: old, to: alarm)
                    if !summary.isEmpty { changed.append((alarm, summary)) }
                }
            }
            knownRevisions[alarm.id] = alarm.revision
        }
        let ids = Set(sorted.map(\.id))
        unseen.formIntersection(ids)
        knownRevisions = knownRevisions.filter { ids.contains($0.key) }
        alarms = sorted
        hasLoaded = true
        for alarm in fresh where settings.showsTests || !alarm.isTest {
            onNewAlarm?(alarm)
        }
        for (alarm, summary) in changed where settings.showsTests || !alarm.isTest {
            onChangedAlarm?(alarm, summary)
        }
    }

    /// Kurzfassung eines neuen Stands; leer, wenn sich nichts Sichtbares geändert hat.
    static func changeSummary(from old: AlamosAlarm, to new: AlamosAlarm) -> [String] {
        if new.isClosed { return old.isClosed ? [] : ["In FE2 geschlossen"] }
        var summary = new.data.changes(since: AlarmSnapshot(old.data)).summary
        if summary.isEmpty, old.isClosed { summary = ["In FE2 wieder geöffnet"] }
        return summary
    }

    // MARK: Beispieldaten

    /// Für Bildschirmfotos: zwei Einsätze ohne Netz.
    func loadDemo() {
        let base = now()
        apply(AlamosDemo.alarms(now: base))
        lastSuccess = base
    }
}

/// Hinweis auf einen neuen Einsatz: Haptik und Mitteilung (auch im Vordergrund als Banner,
/// siehe `ELRDNotificationDelegate`). Ohne Patientennamen – der Sperrbildschirm ist sichtbar.
@MainActor
enum AlamosAlert {
    static func announce(_ alarm: AlamosAlarm) {
        // Schritt 144: Hat das Backend schon per Push gemeldet, nicht noch einmal.
        let identifier = AlamosAnnouncements.identifier(for: alarm.id)
        guard AlamosAnnouncements.claim(identifier) else { return }
        let id = alarm.id
        UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
            let shown = delivered.contains { $0.request.identifier == identifier || AlamosAlert.alarmID(of: $0) == id }
            guard !shown else { return }
            Task { @MainActor in AlamosAlert.post(alarm, identifier: identifier) }
        }
    }

    /// Einsatz einer zugestellten Push-Mitteilung des Backends.
    private nonisolated static func alarmID(of notification: UNNotification) -> UUID? {
        let elrd = notification.request.content.userInfo["elrd"] as? [String: Any]
        return (elrd?["alarmId"] as? String).flatMap(UUID.init(uuidString:))
    }

    private static func post(_ alarm: AlamosAlarm, identifier: String) {
        Haptics.warning()
        let data = alarm.data
        let content = UNMutableNotificationContent()
        content.title = alarm.isTest ? "Neuer Testeinsatz (Alamos FE2)" : "Neuer Einsatz aus Alamos FE2"
        let place = data.location?.city ?? data.location?.street
        content.body = [data.keyword, data.title == data.keyword ? nil : data.title, place]
            .compactMap { $0 }
            .joined(separator: " · ")
        content.sound = .default
        content.threadIdentifier = "alamos"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    /// Schritt 143: neuer Stand eines Einsatzes – eine Mitteilung je Meldung
    /// („+1 Fahrzeug nachalarmiert: …“, „+2 Patienten gemeldet“ …), gruppiert je Einsatz.
    static func announceChange(_ alarm: AlamosAlarm, summary: [String]) {
        Haptics.warning()
        let place = alarm.data.location?.city ?? alarm.data.location?.street
        let subject = [alarm.data.keyword, place].compactMap { $0 }.joined(separator: " · ")
        for (index, line) in summary.enumerated() {
            let content = UNMutableNotificationContent()
            content.title = (alarm.isTest ? "Testeinsatz geändert" : "Einsatz geändert") + (subject.isEmpty ? " (Alamos FE2)" : ": \(subject)")
            content.body = line
            content.sound = index == 0 ? .default : nil
            content.threadIdentifier = "alamos-\(alarm.id.uuidString)"
            let request = UNNotificationRequest(identifier: "alamos-\(alarm.id.uuidString)-\(alarm.revision)-\(index)", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
        }
    }
}

/// Beispiel-Einsätze (erfunden, Funkrufnamen aus den Stammdaten Schweinfurt).
enum AlamosDemo {
    static let busNumber = "2611-04711"

    /// Schritt 143: erster Stand des Bus-Einsatzes, wie er übernommen wurde
    /// (Stand 2 bringt Stichwort RD 4, zwei Fahrzeuge, einen Patienten und Alarmtext).
    static func importedBus(now: Date) -> AlamosAlarm {
        let current = alarms(now: now)[0]
        var data = current.data
        data.keyword = "RD 3"
        data.keywordDescription = "VU Reisebus"
        data.message = Array(data.message.prefix(1))
        data.patients = Array(data.patients.prefix(2))
        data.vehicles = Array(data.vehicles.prefix(3))
        return AlamosAlarm(externalId: busNumber, revision: 1, receivedAt: current.receivedAt, sender: current.sender, isTest: true, data: data)
    }

    static func alarms(now: Date) -> [AlamosAlarm] {
        let bus = AlamosAlarmData(
            externalId: "2611-04711",
            keyword: "RD 4",
            keywordDescription: "VU Reisebus, mehrere Verletzte (MANV)",
            message: ["Reisebus auf Seite, ca. 20 Insassen.", "Zufahrt über AS Schweinfurt/Werneck."],
            location: AlamosLocation(coordinate: [10.1003, 49.9811], street: "A 70", postalCode: "97440", city: "Werneck"),
            caller: AlamosCaller(name: "Testanrufer", contact: "0000 000000"),
            patients: [
                AlamosPatient(remark: "eingeklemmt, Bein deformiert", patientNumber: "1"),
                AlamosPatient(remark: "Kopfplatzwunde, gehfähig", patientNumber: "2"),
                AlamosPatient(remark: "Thoraxschmerz, blass", patientNumber: "3"),
            ],
            vehicles: ["RK SWFT 71/1", "JOH SWFT 71/1", "RK WRNCK 71/1", "RK SWFT 76/1", "BRK FW 11/1"].map { name in
                AlamosVehicle(name: name, radioName: name, alarmedTime: (now.timeIntervalSince1970 - 240) * 1000)
            }
        )
        let fall = AlamosAlarmData(
            externalId: "2611-04698",
            keyword: "RD 1",
            keywordDescription: "Sturz aus Höhe",
            message: ["Person vom Gerüst gestürzt, ansprechbar."],
            location: AlamosLocation(coordinate: [10.2341, 50.0494], street: "Markt", house: "1", postalCode: "97421", city: "Schweinfurt"),
            vehicles: [AlamosVehicle(name: "RK SWFT 71/2", radioName: "RK SWFT 71/2")]
        )
        return [
            AlamosAlarm(externalId: busNumber, revision: 2, receivedAt: now.addingTimeInterval(-240), updatedAt: now.addingTimeInterval(-60), sender: "ILS Schweinfurt", isTest: true, data: bus),
            AlamosAlarm(externalId: "2611-04698", receivedAt: now.addingTimeInterval(-55 * 60), sender: "ILS Schweinfurt", isTest: true, data: fall),
        ]
    }
}
