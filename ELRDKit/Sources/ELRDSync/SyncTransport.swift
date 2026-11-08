import Foundation
import ELRDDomain

// MARK: - Schnittstelle zum Server (Schritt 53)

/// Stelle im Ereignisstrom eines Einsatzes auf dem Server. Der Server vergibt
/// fortlaufende Nummern in der Reihenfolge, in der Ereignisse bei ihm ankommen
/// (nicht nach HLC) – so verpasst ein Gerät beim Abholen nie etwas.
///
/// Dienste mit eigenem, undurchsichtigem Stand (CloudKit: `CKServerChangeToken`)
/// legen ihn in `token` ab; `position` zählt dann nur mit.
public struct SyncCursor: Hashable, Codable, Sendable, Comparable {
    public let position: Int64
    /// Undurchsichtiger Stand des Dienstes (nur zurückgeben, nie auswerten).
    public let token: Data?

    public init(_ position: Int64, token: Data? = nil) {
        self.position = position
        self.token = token
    }

    public static func < (lhs: SyncCursor, rhs: SyncCursor) -> Bool { lhs.position < rhs.position }
}

/// Eine Seite abgeholter Ereignisse.
public struct SyncPage: Sendable, Equatable {
    public let events: [ChangeEvent]
    /// Position nach dieser Seite – beim nächsten Abholen mitschicken.
    public let cursor: SyncCursor?
    /// `true`, wenn sofort die nächste Seite folgen kann.
    public let hasMore: Bool

    public init(events: [ChangeEvent], cursor: SyncCursor?, hasMore: Bool) {
        self.events = events
        self.cursor = cursor
        self.hasMore = hasMore
    }
}

/// Transport der Änderungsereignisse zwischen Gerät und Server bzw. anderen Geräten.
///
/// Vertrag (für jede Umsetzung, auch das künftige ELRD-Backend):
/// - Einheit ist der Einsatz (`missionID`); Freigabe und Mandantentrennung prüft der Server.
/// - `push` ist idempotent: Ereignisse mit bekannter ID werden ignoriert.
/// - `pull` liefert alle Ereignisse nach `cursor` in Ankunftsreihenfolge, auch die
///   eigenen – das Gerät filtert bereits bekannte selbst heraus.
/// - Ereignisse werden nie verändert oder gelöscht (nur anfügen). Ausnahme: das
///   endgültige Löschen eines ganzen Einsatzes (DSGVO) über `purge`.
/// - Konflikte löst immer das Gerät (`EntityHistory`), nie der Server.
public protocol SyncTransport: Sendable {
    func push(_ events: [ChangeEvent], mission: MissionID) async throws
    func pull(mission: MissionID, after cursor: SyncCursor?, limit: Int) async throws -> SyncPage
    func purge(mission: MissionID) async throws
}

/// Dateien (Fotos, Sprachnotizen, Zeichnungen) zum Einsatz (Schritt 55).
///
/// Dateien werden über ihre Prüfsumme (SHA-256) angesprochen: gleicher Inhalt wird
/// nur einmal übertragen, und der Empfänger prüft, ob er das Richtige bekommen hat.
/// Ereignisse enthalten nur den Verweis (`FileAttachment`), nie die Datei selbst.
public protocol SyncFileTransport: Sendable {
    /// Welche der Prüfsummen dem Server noch fehlen.
    func missingFiles(_ sha256: [String], mission: MissionID) async throws -> [String]
    func uploadFile(_ data: Data, sha256: String, mission: MissionID) async throws
    /// `nil`, wenn der Server die Datei (noch) nicht hat.
    func downloadFile(sha256: String, mission: MissionID) async throws -> Data?
}

/// Fehler beim Synchronisieren.
public enum SyncError: Error, Equatable, Sendable {
    /// Kein Server eingerichtet oder Konto nicht verknüpft.
    case notConnected
    /// Anmeldung am Server abgelaufen oder abgelehnt.
    case unauthorized
    /// Der Einsatz ist für dieses Konto nicht freigegeben.
    case missionNotShared
    /// Keine Verbindung – später automatisch erneut.
    case offline
    /// Der Dienst bittet, es frühestens nach so vielen Sekunden erneut zu versuchen.
    case retryLater(seconds: Double)
    /// Der Stand beim Abholen ist beim Dienst abgelaufen – von vorn abholen
    /// (unschädlich, Übernahme ist idempotent).
    case cursorExpired
    /// Speicher beim Dienst voll (bei iCloud: Speicher der Person, die den Einsatz teilt).
    case storageFull
    /// Schlüssel für die Ende-zu-Ende-Verschlüsselung wurden zurückgesetzt
    /// (iCloud-Schlüsselbund); die Cloud-Kopie muss neu aufgebaut werden.
    case encryptionReset
    case server(String)

    /// Ob ein späterer Versuch von selbst gelingen kann.
    public var isTransient: Bool {
        switch self {
        case .offline, .retryLater, .cursorExpired: true
        case .server: true
        case .notConnected, .unauthorized, .missionNotShared, .storageFull, .encryptionReset: false
        }
    }
}

extension SyncError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notConnected: "Kein Server verbunden. Der Einsatz bleibt auf diesem Gerät."
        case .unauthorized: "Anmeldung am Server abgelaufen. Bitte erneut anmelden."
        case .missionNotShared: "Dieser Einsatz ist für dein Konto nicht freigegeben."
        case .offline: "Keine Verbindung zum Server. Änderungen werden später übertragen."
        case .retryLater: "Der Dienst ist gerade ausgelastet. Es geht gleich automatisch weiter."
        case .cursorExpired: "Der Abgleich beginnt von vorn. Dabei geht nichts verloren."
        case .storageFull: "Der iCloud-Speicher ist voll. Änderungen bleiben auf diesem Gerät, bis wieder Platz ist."
        case .encryptionReset: "Die Verschlüsselung in iCloud wurde zurückgesetzt. Der Einsatz wird neu hochgeladen."
        case .server(let message): "Server meldet: \(message)"
        }
    }
}

/// Kein Server: alles bleibt lokal (Standard, solange kein Backend verbunden ist).
public struct LocalOnlyTransport: SyncTransport {
    public init() {}
    public func push(_ events: [ChangeEvent], mission: MissionID) async throws { throw SyncError.notConnected }
    public func pull(mission: MissionID, after cursor: SyncCursor?, limit: Int) async throws -> SyncPage {
        throw SyncError.notConnected
    }
    public func purge(mission: MissionID) async throws { throw SyncError.notConnected }
}

/// Referenz-Server im Arbeitsspeicher: verhält sich wie das künftige Backend.
/// Für Tests (zwei Geräte) und als ausführbare Beschreibung des Vertrags.
public actor InMemorySyncServer: SyncTransport, SyncFileTransport {
    private var logs: [MissionID: [ChangeEvent]] = [:]
    private var known: Set<ChangeEventID> = []
    /// Für Tests: nächster Aufruf scheitert mit diesem Fehler.
    private var nextFailure: SyncError?
    /// Für Tests: Wartezeit je Aufruf (macht Überschneidungen sichtbar).
    private var delay: Duration = .zero
    /// Für Tests: Anzahl der Aufrufe von `push`.
    public private(set) var pushCalls = 0

    public init() {}

    public func failNextCall(with error: SyncError) {
        nextFailure = error
    }

    public func setDelay(_ delay: Duration) {
        self.delay = delay
    }

    public func push(_ events: [ChangeEvent], mission: MissionID) async throws {
        pushCalls += 1
        try await pause()
        try checkFailure()
        for event in events where event.missionID == mission && known.insert(event.id).inserted {
            logs[mission, default: []].append(event)
        }
    }

    public func pull(mission: MissionID, after cursor: SyncCursor?, limit: Int) async throws -> SyncPage {
        try await pause()
        try checkFailure()
        let log = logs[mission] ?? []
        let start = Int(cursor?.position ?? 0)
        guard start < log.count else { return SyncPage(events: [], cursor: cursor, hasMore: false) }
        let end = min(log.count, start + max(limit, 1))
        return SyncPage(events: Array(log[start..<end]), cursor: SyncCursor(Int64(end)), hasMore: end < log.count)
    }

    public func purge(mission: MissionID) async throws {
        try checkFailure()
        for event in logs[mission] ?? [] { known.remove(event.id) }
        logs[mission] = nil
        files[mission] = nil
    }

    // Dateien je Einsatz, nach Prüfsumme.
    private var files: [MissionID: [String: Data]] = [:]

    public func missingFiles(_ sha256: [String], mission: MissionID) async throws -> [String] {
        try checkFailure()
        let stored = files[mission] ?? [:]
        return sha256.filter { stored[$0] == nil }
    }

    public func uploadFile(_ data: Data, sha256: String, mission: MissionID) async throws {
        try checkFailure()
        files[mission, default: [:]][sha256] = data
    }

    public func downloadFile(sha256: String, mission: MissionID) async throws -> Data? {
        try checkFailure()
        return files[mission]?[sha256]
    }

    /// Anzahl gespeicherter Dateien eines Einsatzes.
    public func fileCount(mission: MissionID) -> Int { files[mission]?.count ?? 0 }

    /// Anzahl gespeicherter Ereignisse eines Einsatzes.
    public func eventCount(mission: MissionID) -> Int { logs[mission]?.count ?? 0 }

    private func pause() async throws {
        if delay > .zero { try await Task.sleep(for: delay) }
    }

    private func checkFailure() throws {
        if let failure = nextFailure {
            nextFailure = nil
            throw failure
        }
    }
}

// MARK: - Stand je Einsatz

/// Was ein Gerät für einen Einsatz schon übertragen und abgeholt hat.
public struct SyncCheckpoint: Hashable, Codable, Sendable {
    /// Jüngster bereits hochgeladener Zeitstempel dieses Geräts.
    public var pushedThrough: HybridTimestamp?
    /// Position beim Abholen.
    public var pullCursor: SyncCursor?
    public var lastSyncAt: Date?
    /// Fremde Ereignisse, deren Weg zum Server geklärt ist: vom Server abgeholt
    /// oder von hier weitergeleitet. Liegen mehr fremde Ereignisse vor (Datei,
    /// iPad in der Nähe), leitet das Gerät sie weiter – sonst fehlten sie Geräten,
    /// die nur über den Server abgleichen.
    public var foreignAccounted: Int?

    public init(pushedThrough: HybridTimestamp? = nil, pullCursor: SyncCursor? = nil, lastSyncAt: Date? = nil) {
        self.pushedThrough = pushedThrough
        self.pullCursor = pullCursor
        self.lastSyncAt = lastSyncAt
    }

    /// Setzt den Hochlade-Stand nur vorwärts (überholte Läufe dürfen ihn nie zurücksetzen).
    public mutating func advancePushed(to timestamp: HybridTimestamp?) {
        guard let timestamp else { return }
        pushedThrough = pushedThrough.map { max($0, timestamp) } ?? timestamp
    }

    /// Fremde Ereignisse, die noch weitergeleitet werden müssen (`nil` = keine).
    public func relay(_ events: [ChangeEvent], device: DeviceID) -> [ChangeEvent]? {
        let foreign = events.filter { $0.deviceID != device }
        guard foreign.count > (foreignAccounted ?? 0) else { return nil }
        return foreign.sorted { $0.timestamp < $1.timestamp }
    }

    /// Eigene, noch nicht hochgeladene Ereignisse in HLC-Reihenfolge. Fremde
    /// Ereignisse (vom Server abgeholt) werden nie zurückgeschickt.
    public func outbox(_ events: [ChangeEvent], device: DeviceID) -> [ChangeEvent] {
        events
            .filter { $0.deviceID == device }
            .filter { event in pushedThrough.map { event.timestamp > $0 } ?? true }
            .sorted { $0.timestamp < $1.timestamp }
    }
}

/// Stände aller Einsätze eines Geräts (Gerätedokument).
public struct SyncCheckpoints: Hashable, Codable, Sendable {
    public private(set) var missions: [String: SyncCheckpoint] = [:]

    public init() {}

    public subscript(mission: MissionID) -> SyncCheckpoint {
        get { missions[mission.rawValue.uuidString] ?? SyncCheckpoint() }
        set { missions[mission.rawValue.uuidString] = newValue }
    }

    public mutating func remove(_ mission: MissionID) {
        missions[mission.rawValue.uuidString] = nil
    }
}
