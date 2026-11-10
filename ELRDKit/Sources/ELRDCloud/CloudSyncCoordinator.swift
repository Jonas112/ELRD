import Foundation
import Observation
import ELRDDomain
import ELRDSync
import ELRDPersistence
import ELRDStore

/// Stand des iCloud-Abgleichs eines Einsatzes (für die Oberfläche).
public struct CloudSyncState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// Abgeglichen bzw. bereit.
        case idle
        case syncing
        /// Vorübergehendes Problem (kein Netz, Dienst ausgelastet); neuer Versuch um `retryAt`.
        case waiting
        /// Braucht Eingreifen (kein iCloud-Konto, Speicher voll, …).
        case failed
        /// Freigabe beendet oder Zone gelöscht – lokale Kopie bleibt.
        case revoked
    }

    public var phase: Phase = .idle
    public var message: String?
    public var lastSyncAt: Date?
    public var retryAt: Date?

    public init() {}
}

/// Steuert den iCloud-Abgleich aller verbundenen Einsätze.
///
/// **Wettläufe** (alles auf dem Main Actor, Zustand ändert sich nur zwischen `await`):
/// - *Viele Auslöser* (Push, Zeitgeber, eigene Änderung, Vordergrund): je Einsatz
///   ein Lauf; Auslöser währenddessen merken sich „noch einmal“ und führen zu genau
///   einem Folgelauf. Eigene Änderungen werden kurz gesammelt (`debounce`).
/// - *Doppelte Aktionen* (zweimal „Teilen“, Link zweimal geöffnet): je Einsatz bzw.
///   Link eine laufende Aufgabe, weitere Aufrufe warten auf deren Ergebnis.
/// - *Verlassen, Teilen beenden, Kontowechsel* während eines Laufs: der Einsatz
///   wird zuerst gesperrt (`suspended`), dann wird auf das Ende aller Läufe gewartet;
///   erst danach werden Stand und Verbindung verworfen. So schreibt kein
///   verspäteter Lauf alte Stände zurück.
/// - *Wartezeiten*: nach Fehlern höchstens ein geplanter Neuversuch je Einsatz;
///   Auslöser in der Wartezeit lösen keinen Sturm von Anfragen aus.
@MainActor
@Observable
public final class CloudSyncCoordinator {
    public private(set) var states: [MissionID: CloudSyncState] = [:]
    /// iCloud nicht verfügbar (kein Konto, MDM-Sperre) – Grund für die Oberfläche.
    public private(set) var accountProblem: String?

    /// Schritt 116: offene Beitrittsanfragen an eigene Freigaben (Einsatzleitung).
    public private(set) var joinRequests: [JoinRequestItem] = []
    /// Eigene Anfragen, die auf Antwort warten (Spiegel des Verzeichnisses, beobachtbar).
    public private(set) var pendingJoins: [PendingJoin] = []
    /// Neue Freigaben nur für zugelassene Personen (Einstellung, Schritt 116).
    @ObservationIgnored public var requiresJoinApproval = false
    /// Nach Zulassung einer eigenen Anfrage beigetreten.
    @ObservationIgnored public var onJoinApproved: ((MissionID) -> Void)?
    @ObservationIgnored private var checkingJoins = false

    /// Nach übernommenen fremden Änderungen: offene Einsätze neu laden.
    @ObservationIgnored public var onImported: ((Set<MissionID>) -> Void)?

    @ObservationIgnored private let repository: any EntityRepository & DocumentRepository
    @ObservationIgnored private let store: any CloudZoneStore
    @ObservationIgnored private let transport: CloudKitTransport
    @ObservationIgnored private let engine: SyncEngine
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let sleep: @Sendable (Double) async throws -> Void

    /// Wartezeit zum Sammeln eigener Änderungen.
    @ObservationIgnored public var debounceSeconds: Double = 1.5
    /// Abstand des Nachsehens im Vordergrund (Push ist nicht garantiert).
    @ObservationIgnored public var pollSeconds: Double = 15

    @ObservationIgnored private var activation: Task<Void, Never>?
    @ObservationIgnored private var activated = false
    @ObservationIgnored private var inFlight: [MissionID: Task<Void, Never>] = [:]
    @ObservationIgnored private var rerun: Set<MissionID> = []
    @ObservationIgnored private var suspended: Set<MissionID> = []
    @ObservationIgnored private var debounce: [MissionID: Task<Void, Never>] = [:]
    @ObservationIgnored private var wake: [MissionID: Task<Void, Never>] = [:]
    @ObservationIgnored private var failures: [MissionID: Int] = [:]
    @ObservationIgnored private var sharing: [MissionID: Task<URL, any Error>] = [:]
    @ObservationIgnored private var joining: [URL: Task<MissionID, any Error>] = [:]
    @ObservationIgnored private var polling: Task<Void, Never>?

    public init(
        repository: any EntityRepository & DocumentRepository,
        clock: DeviceClock,
        deviceID: DeviceID,
        files: AttachmentFileStore?,
        store: any CloudZoneStore,
        now: @escaping () -> Date = Date.init,
        sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.repository = repository
        self.store = store
        self.now = now
        self.sleep = sleep
        transport = CloudKitTransport(store: store)
        engine = SyncEngine(repository: repository, transport: transport, clock: clock, deviceID: deviceID, files: files, now: now)
        pendingJoins = (try? directory())?.pendingJoins ?? []
    }

    // MARK: Abfragen

    public func link(for mission: MissionID) -> CloudMissionLink? {
        (try? directory())?[mission]
    }

    /// Ob überhaupt Einsätze mit iCloud verbunden sind (sonst CloudKit gar nicht anfassen).
    public var hasLinks: Bool {
        !((try? directory())?.isEmpty ?? true)
    }

    public func state(for mission: MissionID) -> CloudSyncState {
        states[mission] ?? CloudSyncState()
    }

    /// Eigene Änderungen, die noch nicht in iCloud sind.
    public func pendingCount(for mission: MissionID) -> Int {
        guard link(for: mission) != nil else { return 0 }
        return (try? engine.pendingCount(for: mission)) ?? 0
    }

    // MARK: Start und Konto

    /// Prüft das Konto, verbindet alle Einsätze und gleicht ab. Mehrfachaufrufe
    /// teilen sich einen Durchgang.
    public func activate() async {
        if let activation { return await activation.value }
        let task = Task { @MainActor in
            await self.checkAccount()
            do { try await self.store.subscribeToChanges() } catch {}
            self.activated = true
            for mission in (try? self.directory().missions) ?? [] { self.requestSync(mission) }
        }
        activation = task
        await task.value
        activation = nil
    }

    /// iCloud-Konto gewechselt oder abgemeldet (`CKAccountChanged`).
    public func accountDidChange() async {
        await activate()
    }

    private func checkAccount() async {
        var stored = (try? directory()) ?? CloudMissionDirectory()
        let current: String
        do {
            current = try await store.accountID()
            accountProblem = nil
        } catch CloudStoreError.notSignedIn {
            accountProblem = CloudStoreError.notSignedIn.errorDescription
            await transport.disconnectAll()
            return
        } catch {
            // Ohne Netz bleibt das bekannte Konto gültig; Aufrufe warten dann auf Netz.
            await connectAll(stored)
            return
        }

        if let known = stored.accountID, known != current {
            // Anderes Konto: Zonen und Stände gehören dem alten. Erst alle Läufe
            // beenden, dann verwerfen – die Einsätze bleiben lokal erhalten.
            let missions = stored.missions
            suspended.formUnion(missions)
            await transport.disconnectAll()
            for mission in missions { await settle(mission) }
            for mission in missions {
                try? engine.forget(mission)
                states[mission] = nil
                failures[mission] = nil
            }
            stored = CloudMissionDirectory(accountID: current)
            try? save(stored)
            suspended.subtract(missions)
            return
        }
        if stored.accountID == nil {
            stored.accountID = current
            try? save(stored)
        }
        await connectAll(stored)
    }

    private func connectAll(_ directory: CloudMissionDirectory) async {
        for mission in directory.missions {
            if let link = directory[mission] { await transport.connect(mission, to: link.zone) }
        }
    }

    // MARK: Teilen und Beitreten

    /// Gibt den Einsatz frei und liefert den Einladungslink. Doppelte Aufrufe
    /// (zweimal getippt) teilen sich eine Aufgabe. Danach `requestSync` aufrufen.
    public func startSharing(_ mission: MissionID, title: String) async throws -> URL {
        if let running = sharing[mission] { return try await running.value }
        let task = Task { @MainActor () throws -> URL in
            if !self.activated { await self.activate() }
            if let problem = self.accountProblem { throw CloudShareError.account(problem) }
            if let existing = self.link(for: mission), !existing.isOwner, let url = existing.shareURL {
                return url
            }
            let zone = self.link(for: mission)?.zone ?? .owned(mission)
            let approval = self.requiresJoinApproval
            let url = try await self.store.share(zone, title: title, requiresApproval: approval)
            try self.updateDirectory { directory in
                let isFirstShare = directory[mission]?.shareURL == nil
                var link = directory[mission] ?? CloudMissionLink(zone: zone, shareURL: url, linkedAt: self.now())
                // Bestehende Freigabe behält ihre Art; nur beim ersten Teilen festhalten.
                if isFirstShare { link.requiresApproval = approval ? true : nil }
                link.shareURL = url
                directory[mission] = link
            }
            self.suspended.remove(mission)
            await self.transport.connect(mission, to: zone)
            // Hochladen stößt der Aufrufer an (`requestSync`): Der Link soll sofort
            // angezeigt werden, auch wenn der erste Abgleich bei großen Einsätzen dauert.
            return url
        }
        sharing[mission] = task
        defer { sharing[mission] = nil }
        return try await task.value
    }

    /// Tritt über einen Einladungslink bei. Liefert den Einsatz; seine Daten kommen
    /// mit dem ersten Abgleich.
    public func join(_ url: URL) async throws -> MissionID {
        if let running = joining[url] { return try await running.value }
        let task = Task { @MainActor () throws -> MissionID in
            if !self.activated { await self.activate() }
            if let problem = self.accountProblem { throw CloudShareError.account(problem) }
            let zone: CloudZone
            do {
                zone = try await self.store.accept(url)
            } catch let error as CloudStoreError where error == .permissionDenied || error == .zoneMissing {
                // Link gilt nicht für jeden: Beitritt muss genehmigt werden (oder
                // die Freigabe ist beendet) – die Oberfläche bietet eine Anfrage an.
                throw CloudShareError.approvalRequired
            }
            return try await self.connectJoined(zone, url: url)
        }
        joining[url] = task
        defer { joining[url] = nil }
        return try await task.value
    }

    /// Einladung, die das System schon angenommen hat (Link aus Nachrichten).
    public func joinAccepted(_ zone: CloudZone, url: URL?) async throws -> MissionID {
        if !activated { await activate() }
        return try await connectJoined(zone, url: url)
    }

    private func connectJoined(_ zone: CloudZone, url: URL?) async throws -> MissionID {
        guard let mission = zone.missionID else { throw CloudShareError.invalidLink }
        try updateDirectory { directory in
            if var existing = directory[mission], existing.zone == zone {
                existing.shareURL = existing.shareURL ?? url
                directory[mission] = existing
            } else {
                directory[mission] = CloudMissionLink(zone: zone, shareURL: url, linkedAt: now())
            }
        }
        suspended.remove(mission)
        states[mission] = CloudSyncState()
        await transport.connect(mission, to: zone)
        await syncNow(mission)
        return mission
    }

    // MARK: Beitritt mit Genehmigung (Schritt 116)

    /// Bittet die Einsatzleitung um Zulassung. Erneutes Anfragen überschreibt.
    public func requestJoin(_ url: URL, displayName: String) async throws {
        if !activated { await activate() }
        if let problem = accountProblem { throw CloudShareError.account(problem) }
        let userID = try await store.currentUserID()
        let shareKey = JoinSeal.shareKey(for: url)
        let name = JoinSeal.requestName(shareKey: shareKey, userID: userID)
        let payload = JoinRequestPayload(userID: userID, displayName: displayName, requestedAt: now())
        try await store.submitJoinRequest(SealedJoinRequest(name: name, shareKey: shareKey, sealed: try JoinSeal.seal(payload, url: url)))
        try updateDirectory { directory in
            var pending = (directory.pendingJoins ?? []).filter { $0.requestName != name }
            pending.append(PendingJoin(url: url, requestName: name, requestedAt: now(), status: .waiting))
            directory.pendingJoins = pending
        }
    }

    /// Eigene Anfrage verwerfen (auch nach Ablehnung).
    public func cancelJoinRequest(_ pending: PendingJoin) async {
        try? await store.withdrawJoinRequest(name: pending.requestName)
        try? updateDirectory { $0.pendingJoins = ($0.pendingJoins ?? []).filter { $0.requestName != pending.requestName } }
    }

    /// Beide Seiten nachsehen: eigene Anfragen (zugelassen → beitreten) und Anfragen
    /// an eigene Freigaben. Läuft höchstens einmal gleichzeitig.
    public func checkJoinRequests() async {
        guard !checkingJoins else { return }
        checkingJoins = true
        defer { checkingJoins = false }
        guard let current = try? directory() else { return }
        if !(current.pendingJoins ?? []).isEmpty || !current.ownedShares.isEmpty, !activated { await activate() }
        for pending in current.pendingJoins ?? [] where pending.status == .waiting {
            guard let decision = try? await store.joinDecision(requestName: pending.requestName) else { continue }
            switch decision {
            case .approved:
                guard let mission = try? await join(pending.url) else { continue }
                try? await store.withdrawJoinRequest(name: pending.requestName)
                try? updateDirectory { $0.pendingJoins = ($0.pendingJoins ?? []).filter { $0.requestName != pending.requestName } }
                onJoinApproved?(mission)
            case .denied:
                try? await store.withdrawJoinRequest(name: pending.requestName)
                try? updateDirectory { directory in
                    directory.pendingJoins = (directory.pendingJoins ?? []).map {
                        var updated = $0
                        if updated.requestName == pending.requestName { updated.status = .denied }
                        return updated
                    }
                }
            }
        }
        await refreshOwnedJoinRequests(current)
    }

    private func refreshOwnedJoinRequests(_ current: CloudMissionDirectory) async {
        let shares = current.ownedShares
        guard !shares.isEmpty else {
            if !joinRequests.isEmpty { joinRequests = [] }
            return
        }
        let byKey = Dictionary(shares.map { (JoinSeal.shareKey(for: $0.url), $0) }, uniquingKeysWith: { first, _ in first })
        guard let sealed = try? await store.joinRequests(shareKeys: Array(byKey.keys)) else { return }
        let decided = Set((try? directory())?.decidedJoinRequests ?? [])
        let items = sealed.compactMap { request -> JoinRequestItem? in
            guard !decided.contains(request.name), let share = byKey[request.shareKey],
                  let payload = try? JoinSeal.open(request.sealed, url: share.url) else { return nil }
            return JoinRequestItem(id: request.name, mission: share.mission, payload: payload)
        }
        .sorted { $0.payload.requestedAt < $1.payload.requestedAt }
        if items != joinRequests { joinRequests = items }
    }

    /// Einsatzleitung: Anfrage zulassen (Teilnehmer der Freigabe) oder ablehnen.
    public func decide(_ request: JoinRequestItem, approve: Bool) async throws {
        guard let link = link(for: request.mission), link.isOwner else { throw CloudShareError.invalidLink }
        if approve { try await store.admit(userID: request.payload.userID, to: link.zone) }
        try await store.submitJoinDecision(approve ? .approved : .denied, requestName: request.id)
        try updateDirectory { directory in
            var decided = directory.decidedJoinRequests ?? []
            decided.append(request.id)
            directory.decidedJoinRequests = Array(decided.suffix(200))
        }
        joinRequests.removeAll { $0.id == request.id }
    }

    /// Beendet die Verbindung des Einsatzes mit iCloud. Eigentümer: Freigabe
    /// beenden und Cloud-Kopie löschen; Beigetretene: Teilnahme beenden.
    /// Die lokale Kopie bleibt immer erhalten.
    public func disconnect(_ mission: MissionID) async throws {
        guard let link = link(for: mission) else { return }
        suspended.insert(mission)
        await settle(mission)
        do {
            if link.isOwner { try await store.stopSharing(link.zone) }
            try await store.deleteZone(link.zone)
        } catch let error as CloudStoreError where error != .network {
            // Freigabe/Zone schon weg o. Ä.: lokal trotzdem trennen.
        } catch {
            suspended.remove(mission)
            throw error
        }
        await transport.disconnect(mission)
        try? engine.forget(mission)
        try updateDirectory { $0[mission] = nil }
        states[mission] = nil
        failures[mission] = nil
        suspended.remove(mission)
    }

    // MARK: Auslöser

    /// Eigene Änderung gespeichert: kurz sammeln, dann abgleichen.
    public func noteLocalChange(_ mission: MissionID) {
        guard link(for: mission) != nil, !suspended.contains(mission) else { return }
        debounce[mission]?.cancel()
        let delay = debounceSeconds
        debounce[mission] = Task { @MainActor in
            do { try await self.sleep(delay) } catch { return }
            self.debounce[mission] = nil
            self.requestSync(mission)
        }
    }

    /// Push-Mitteilung, App im Vordergrund: alle verbundenen Einsätze abgleichen.
    public func syncAll() {
        for mission in (try? directory().missions) ?? [] { requestSync(mission) }
    }

    /// Alle verbundenen Einsätze abgleichen und darauf warten – höchstens `timeout`
    /// Sekunden (Push im Hintergrund: das System gibt nur kurz Zeit).
    public func syncAllNow(timeout: Double) async {
        if !activated { await activate() }
        let missions = (try? directory().missions) ?? []
        guard !missions.isEmpty else { return }
        let sleep = self.sleep
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                for mission in missions { await self.syncNow(mission) }
            }
            group.addTask { try? await sleep(timeout) }
            await group.next()
            group.cancelAll()
        }
    }

    /// Solange ein Einsatz offen ist, regelmäßig nachsehen (Push kann ausbleiben).
    public func startPolling(_ mission: MissionID) {
        polling?.cancel()
        guard link(for: mission) != nil else { polling = nil; return }
        let interval = pollSeconds
        polling = Task { @MainActor in
            while !Task.isCancelled {
                self.requestSync(mission)
                do { try await self.sleep(interval) } catch { return }
            }
        }
    }

    public func stopPolling() {
        polling?.cancel()
        polling = nil
    }

    /// Abgleich anstoßen – sofort, außer während einer Wartezeit nach Fehlern.
    public func requestSync(_ mission: MissionID) {
        guard link(for: mission) != nil, !suspended.contains(mission) else { return }
        if let retryAt = states[mission]?.retryAt, retryAt > now() {
            scheduleWake(mission, at: retryAt)
            return
        }
        Task { @MainActor in await self.syncNow(mission) }
    }

    /// Gleicht sofort ab. Läuft schon ein Abgleich, folgt genau einer danach.
    public func syncNow(_ mission: MissionID) async {
        guard link(for: mission) != nil, !suspended.contains(mission) else { return }
        if let running = inFlight[mission] {
            rerun.insert(mission)
            await running.value
            return
        }
        let task = Task { @MainActor in
            repeat {
                self.rerun.remove(mission)
                await self.runOnce(mission)
            } while self.rerun.contains(mission) && !self.suspended.contains(mission)
                && self.states[mission]?.phase == .idle
            self.rerun.remove(mission)
            self.inFlight[mission] = nil
        }
        inFlight[mission] = task
        await task.value
    }

    /// Wartet, bis für den Einsatz nichts mehr läuft (Koordinator und Engine).
    private func settle(_ mission: MissionID) async {
        debounce[mission]?.cancel()
        debounce[mission] = nil
        wake[mission]?.cancel()
        wake[mission] = nil
        while let running = inFlight[mission] { await running.value }
        await engine.waitUntilIdle(mission)
    }

    // MARK: Ein Lauf

    private func runOnce(_ mission: MissionID, rebuilding: Bool = false) async {
        var state = self.state(for: mission)
        state.phase = .syncing
        states[mission] = state
        do {
            let report = try await engine.sync(mission)
            guard !suspended.contains(mission) else { return }
            failures[mission] = nil
            state.phase = .idle
            state.message = nil
            state.retryAt = nil
            state.lastSyncAt = now()
            states[mission] = state
            if report.imported.newEvents > 0 { onImported?([mission]) }
        } catch let error as SyncError {
            guard !suspended.contains(mission) else { return }
            await handle(error, mission: mission, rebuilding: rebuilding)
        } catch {
            guard !suspended.contains(mission) else { return }
            backOff(mission, after: nil, message: error.localizedDescription)
        }
    }

    private func handle(_ error: SyncError, mission: MissionID, rebuilding: Bool) async {
        switch error {
        case .retryLater(let seconds):
            backOff(mission, after: seconds, message: error.errorDescription)
        case .offline, .server, .cursorExpired:
            backOff(mission, after: nil, message: error.errorDescription)
        case .storageFull:
            backOff(mission, after: 600, message: error.errorDescription, phase: .failed)
        case .unauthorized:
            accountProblem = CloudStoreError.notSignedIn.errorDescription
            fail(mission, phase: .failed, message: accountProblem)
        case .missionNotShared:
            suspended.insert(mission)
            fail(mission, phase: .revoked, message: "Der Einsatz wird nicht mehr geteilt. Die Daten auf diesem Gerät bleiben erhalten.")
        case .notConnected:
            states[mission] = nil
        case .encryptionReset:
            guard let link = link(for: mission), link.isOwner, !rebuilding else {
                fail(mission, phase: .failed, message: error.errorDescription)
                return
            }
            await rebuild(mission, zone: link.zone)
        }
    }

    /// Schlüssel im iCloud-Schlüsselbund zurückgesetzt: Die eigene Cloud-Kopie ist
    /// unlesbar. Zone neu anlegen und alles aus der lokalen Kopie neu hochladen
    /// (eigene und weitergeleitete fremde Ereignisse).
    private func rebuild(_ mission: MissionID, zone: CloudZone) async {
        do {
            try await store.deleteZone(zone)
            await transport.forgetEnsured(zone)
            try engine.forget(mission)
        } catch {
            backOff(mission, after: nil, message: error.localizedDescription)
            return
        }
        await runOnce(mission, rebuilding: true)
    }

    private func fail(_ mission: MissionID, phase: CloudSyncState.Phase, message: String?) {
        var state = self.state(for: mission)
        state.phase = phase
        state.message = message
        state.retryAt = nil
        states[mission] = state
    }

    /// Wartezeit: Vorgabe des Dienstes, sonst 5, 10, 20 … höchstens 300 s.
    private func backOff(_ mission: MissionID, after seconds: Double?, message: String?, phase: CloudSyncState.Phase = .waiting) {
        let attempt = (failures[mission] ?? 0) + 1
        failures[mission] = attempt
        let delay = seconds ?? min(300, 5 * pow(2, Double(attempt - 1)))
        var state = self.state(for: mission)
        state.phase = phase
        state.message = message
        state.retryAt = now().addingTimeInterval(delay)
        states[mission] = state
        scheduleWake(mission, at: state.retryAt!)
    }

    /// Höchstens ein geplanter Neuversuch je Einsatz.
    private func scheduleWake(_ mission: MissionID, at date: Date) {
        guard wake[mission] == nil else { return }
        let delay = max(0, date.timeIntervalSince(now()))
        wake[mission] = Task { @MainActor in
            do { try await self.sleep(delay) } catch { return }
            self.wake[mission] = nil
            guard !self.suspended.contains(mission) else { return }
            if var state = self.states[mission] {
                state.retryAt = nil
                self.states[mission] = state
            }
            await self.syncNow(mission)
        }
    }

    // MARK: Verzeichnis

    private func directory() throws -> CloudMissionDirectory {
        try repository.document(CloudMissionDirectory.self, key: .cloudMissions) ?? CloudMissionDirectory()
    }

    private func save(_ directory: CloudMissionDirectory) throws {
        try repository.saveDocument(directory, key: .cloudMissions, at: now())
        let pending = directory.pendingJoins ?? []
        if pending != pendingJoins { pendingJoins = pending }
    }

    /// Lesen, ändern, schreiben – ohne `await` dazwischen, also nie verschränkt.
    private func updateDirectory(_ change: (inout CloudMissionDirectory) -> Void) throws {
        var current = try directory()
        change(&current)
        try save(current)
    }
}

/// Fehler beim Teilen oder Beitreten (für die Oberfläche).
public enum CloudShareError: Error, Equatable, LocalizedError {
    case account(String)
    case invalidLink
    /// Link gilt nicht (mehr) für jeden: Beitritt anfragen (Schritt 116).
    case approvalRequired

    public var errorDescription: String? {
        switch self {
        case .account(let message): message
        case .invalidLink: "Dieser Link ist keine ELRD-Einladung."
        case .approvalRequired: "Kein Zugriff über diesen Link. Wenn die Einsatzleitung Beitritte genehmigt, kannst du den Beitritt anfragen – sonst wurde das Teilen beendet."
        }
    }
}
