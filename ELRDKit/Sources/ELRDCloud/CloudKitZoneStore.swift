import Foundation
import CloudKit

/// `CloudZoneStore` über CloudKit.
///
/// - Eigene Zonen in der privaten, beigetretene in der geteilten Datenbank.
/// - Ereignisinhalt im verschlüsselten Feld `payload` (`encryptedValues`, Schlüssel
///   im iCloud-Schlüsselbund – Apple kann ihn nicht lesen); Dateien als `CKAsset`,
///   die CloudKit ebenso über den Schlüsselbund verschlüsselt.
/// - Freigabe als zonenweiter `CKShare` mit „Jeder mit dem Link kann bearbeiten“.
///
/// Der Container wird erst beim ersten Zugriff erzeugt: Ohne iCloud-Berechtigung
/// (Simulator-Builds im CI) bricht `CKContainer` sonst schon beim Start ab.
public final class CloudKitZoneStore: CloudZoneStore, @unchecked Sendable {
    /// Container der App (muss im Entwicklerkonto angelegt sein, siehe docs/SYNC.md).
    public static let containerIdentifier = "iCloud.ELRD.App"

    private static let payloadKey = "payload"
    private static let assetKey = "asset"
    private static let privateSubscription = "elrd-private-changes"
    private static let sharedSubscription = "elrd-shared-changes"

    private let identifier: String
    private let lock = NSLock()
    private var cachedContainer: CKContainer?

    public init(containerIdentifier: String = CloudKitZoneStore.containerIdentifier) {
        identifier = containerIdentifier
    }

    private var container: CKContainer {
        lock.lock()
        defer { lock.unlock() }
        if let cachedContainer { return cachedContainer }
        let created = CKContainer(identifier: identifier)
        cachedContainer = created
        return created
    }

    private func database(_ scope: CloudZone.Scope) -> CKDatabase {
        scope == .owned ? container.privateCloudDatabase : container.sharedCloudDatabase
    }

    private func zoneID(_ zone: CloudZone) -> CKRecordZone.ID {
        let owner = zone.scope == .owned || zone.ownerName == CloudZone.currentUser ? CKCurrentUserDefaultName : zone.ownerName
        return CKRecordZone.ID(zoneName: zone.zoneName, ownerName: owner)
    }

    private func recordID(_ name: String, in zone: CloudZone) -> CKRecord.ID {
        CKRecord.ID(recordName: name, zoneID: zoneID(zone))
    }

    // MARK: Konto

    public func accountID() async throws -> String {
        try await run {
            let status = try await container.accountStatus()
            switch status {
            case .available: break
            case .temporarilyUnavailable: throw CloudStoreError.retry(after: 30)
            default: throw CloudStoreError.notSignedIn
            }
            return try await container.userRecordID().recordName
        }
    }

    // MARK: Zonen

    public func createZone(_ zone: CloudZone) async throws {
        try await run {
            let result = try await database(.owned).modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID(zone))], deleting: [])
            for (_, outcome) in result.saveResults {
                if case .failure(let error) = outcome { throw error }
            }
        }
    }

    public func deleteZone(_ zone: CloudZone) async throws {
        do {
            try await run {
                let result = try await database(zone.scope).modifyRecordZones(saving: [], deleting: [zoneID(zone)])
                for (_, outcome) in result.deleteResults {
                    if case .failure(let error) = outcome { throw error }
                }
            }
        } catch CloudStoreError.zoneMissing {
            // Schon weg – Ziel erreicht.
        }
    }

    // MARK: Datensätze

    public func save(_ records: [CloudRecord], in zone: CloudZone) async throws {
        guard !records.isEmpty else { return }
        var temporaryFiles: [URL] = []
        defer { for url in temporaryFiles { try? FileManager.default.removeItem(at: url) } }

        var ckRecords: [CKRecord] = []
        for record in records {
            let ckRecord = CKRecord(recordType: record.kind.rawValue, recordID: recordID(record.name, in: zone))
            switch record.kind {
            case .event:
                ckRecord.encryptedValues[Self.payloadKey] = record.payload as NSData
            case .file:
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("elrd-upload-\(UUID().uuidString)")
                try record.payload.write(to: url, options: .atomic)
                temporaryFiles.append(url)
                ckRecord[Self.assetKey] = CKAsset(fileURL: url)
            }
            ckRecords.append(ckRecord)
        }

        try await run {
            // `.allKeys`: vorhandene Datensätze gleichen Namens identisch überschreiben
            // (idempotent, keine Konflikte bei Wiederholung). Atomar: alles oder nichts.
            let result = try await database(zone.scope).modifyRecords(
                saving: ckRecords,
                deleting: [],
                savePolicy: .allKeys,
                atomically: true
            )
            if let error = Self.firstRealError(result.saveResults.values) { throw error }
        }
    }

    public func changes(in zone: CloudZone, since token: Data?, limit: Int) async throws -> CloudChangePage {
        let previous = try token.flatMap(Self.decodeToken)
        return try await run {
            let result = try await database(zone.scope).recordZoneChanges(
                inZoneWith: zoneID(zone),
                since: previous,
                desiredKeys: [Self.payloadKey],
                resultsLimit: limit
            )
            var records: [CloudRecord] = []
            for (id, outcome) in result.modificationResultsByID {
                switch outcome {
                case .success(let modification):
                    let ckRecord = modification.record
                    guard let kind = CloudRecord.Kind(rawValue: ckRecord.recordType) else { continue }
                    let payload = (ckRecord.encryptedValues[Self.payloadKey] as? Data) ?? Data()
                    records.append(CloudRecord(name: id.recordName, kind: kind, payload: payload))
                case .failure(let error):
                    throw error
                }
            }
            return CloudChangePage(
                records: records,
                token: try Self.encodeToken(result.changeToken),
                moreComing: result.moreComing
            )
        }
    }

    public func existing(_ names: [String], in zone: CloudZone) async throws -> Set<String> {
        guard !names.isEmpty else { return [] }
        return try await run {
            let ids = names.map { recordID($0, in: zone) }
            let result = try await database(zone.scope).records(for: ids, desiredKeys: [])
            var present: Set<String> = []
            for (id, outcome) in result {
                switch outcome {
                case .success: present.insert(id.recordName)
                case .failure(let error as CKError) where error.code == .unknownItem: continue
                case .failure(let error): throw error
                }
            }
            return present
        }
    }

    public func fetch(_ name: String, in zone: CloudZone) async throws -> CloudRecord? {
        try await run {
            let ckRecord: CKRecord
            do {
                ckRecord = try await database(zone.scope).record(for: recordID(name, in: zone))
            } catch let error as CKError where error.code == .unknownItem {
                return nil
            }
            guard let kind = CloudRecord.Kind(rawValue: ckRecord.recordType) else { return nil }
            switch kind {
            case .event:
                let payload = (ckRecord.encryptedValues[Self.payloadKey] as? Data) ?? Data()
                return CloudRecord(name: name, kind: kind, payload: payload)
            case .file:
                guard let url = (ckRecord[Self.assetKey] as? CKAsset)?.fileURL else { return nil }
                return CloudRecord(name: name, kind: kind, payload: try Data(contentsOf: url))
            }
        }
    }

    // MARK: Freigabe

    public func share(_ zone: CloudZone, title: String) async throws -> URL {
        try await share(zone, title: title, requiresApproval: false)
    }

    /// Mit `requiresApproval` gilt der Link nicht für jeden (`publicPermission = .none`);
    /// Teilnehmer nimmt die Einsatzleitung einzeln auf (`admit`). Eine bestehende
    /// Freigabe behält ihre Art.
    public func share(_ zone: CloudZone, title: String, requiresApproval: Bool) async throws -> URL {
        try await createZone(zone)
        return try await run {
            let database = database(.owned)
            let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID(zone))
            if let existing = try await existingShare(shareID, in: database), let url = existing.url {
                return url
            }
            let share = CKShare(recordZoneID: zoneID(zone))
            share[CKShare.SystemFieldKey.title] = title as CKRecordValue
            share.publicPermission = requiresApproval ? .none : .readWrite
            do {
                // `.ifServerRecordUnchanged`: Hat ein anderes Gerät desselben Kontos
                // gleichzeitig freigegeben, gilt dessen Freigabe.
                let result = try await database.modifyRecords(saving: [share], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
                if let error = Self.firstRealError(result.saveResults.values) { throw error }
                if case .success(let saved as CKShare)? = result.saveResults[shareID], let url = saved.url {
                    return url
                }
            } catch let error as CKError where error.code == .serverRecordChanged || error.code == .partialFailure {
                if error.code == .partialFailure, Self.innerError(of: error)?.code != .serverRecordChanged { throw error }
            }
            guard let current = try await existingShare(shareID, in: database), let url = current.url else {
                throw CloudStoreError.conflict
            }
            return url
        }
    }

    public func stopSharing(_ zone: CloudZone) async throws {
        try await run {
            let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID(zone))
            let result = try await database(.owned).modifyRecords(saving: [], deleting: [shareID])
            for (_, outcome) in result.deleteResults {
                if case .failure(let error as CKError) = outcome, error.code == .unknownItem { continue }
                if case .failure(let error) = outcome { throw error }
            }
        }
    }

    public func accept(_ url: URL) async throws -> CloudZone {
        let metadata = try await run { try await container.shareMetadata(for: url) }
        return try await accept(metadata)
    }

    /// Einladung, die das System übergeben hat (Link in Nachrichten, Kamera).
    public func accept(_ metadata: CKShare.Metadata) async throws -> CloudZone {
        let zoneID = metadata.share.recordID.zoneID
        guard zoneID.zoneName.hasPrefix(CloudZone.namePrefix) else { throw CloudStoreError.invalidShare }
        if metadata.participantRole == .owner {
            // Eigener Link (anderes Gerät desselben Kontos): Zone ist die eigene.
            return CloudZone(scope: .owned, zoneName: zoneID.zoneName, ownerName: CloudZone.currentUser)
        }
        try await run { _ = try await container.accept(metadata) }
        return CloudZone(scope: .joined, zoneName: zoneID.zoneName, ownerName: zoneID.ownerName)
    }

    // MARK: Beitritt mit Genehmigung (Schritt 116)

    private static let joinRequestType = "ELRDJoinRequest"
    private static let joinDecisionType = "ELRDJoinDecision"

    public func currentUserID() async throws -> String {
        try await run { try await container.userRecordID().recordName }
    }

    public func submitJoinRequest(_ request: SealedJoinRequest) async throws {
        try await run {
            let record = CKRecord(recordType: Self.joinRequestType, recordID: CKRecord.ID(recordName: request.name))
            record["shareKey"] = request.shareKey as CKRecordValue
            record["sealed"] = request.sealed as CKRecordValue
            let result = try await container.publicCloudDatabase.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
            if let error = Self.firstRealError(result.saveResults.values) { throw error }
        }
    }

    public func joinRequests(shareKeys: [String]) async throws -> [SealedJoinRequest] {
        guard !shareKeys.isEmpty else { return [] }
        return try await run {
            // Braucht im CloudKit-Schema einen abfragbaren Index auf `shareKey` (docs/SYNC.md).
            let query = CKQuery(recordType: Self.joinRequestType, predicate: NSPredicate(format: "shareKey IN %@", shareKeys))
            let (matches, _) = try await container.publicCloudDatabase.records(matching: query, resultsLimit: 100)
            return matches.compactMap { id, outcome in
                guard case .success(let record) = outcome,
                      let key = record["shareKey"] as? String,
                      let sealed = record["sealed"] as? Data else { return nil }
                return SealedJoinRequest(name: id.recordName, shareKey: key, sealed: sealed)
            }
        }
    }

    public func admit(userID: String, to zone: CloudZone) async throws {
        try await run {
            let database = database(.owned)
            let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID(zone))
            let participant = try await container.shareParticipant(forUserRecordID: CKRecord.ID(recordName: userID))
            participant.permission = .readWrite
            // Zwei Versuche: Hat ein anderes Gerät die Freigabe gerade geändert, neu laden.
            for attempt in 0..<2 {
                guard let share = try await existingShare(shareID, in: database) else { throw CloudStoreError.invalidShare }
                if share.participants.contains(where: { $0.userIdentity.userRecordID?.recordName == userID }) { return }
                share.addParticipant(participant)
                do {
                    let result = try await database.modifyRecords(saving: [share], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
                    if let error = Self.firstRealError(result.saveResults.values) { throw error }
                    return
                } catch let error as CKError where error.code == .serverRecordChanged && attempt == 0 {
                    continue
                }
            }
        }
    }

    public func submitJoinDecision(_ decision: JoinDecision, requestName: String) async throws {
        try await run {
            let id = CKRecord.ID(recordName: JoinSeal.decisionName(requestName: requestName))
            let record = CKRecord(recordType: Self.joinDecisionType, recordID: id)
            record["decision"] = decision.rawValue as CKRecordValue
            let result = try await container.publicCloudDatabase.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
            if let error = Self.firstRealError(result.saveResults.values) { throw error }
        }
    }

    public func joinDecision(requestName: String) async throws -> JoinDecision? {
        try await run {
            let id = CKRecord.ID(recordName: JoinSeal.decisionName(requestName: requestName))
            do {
                let record = try await container.publicCloudDatabase.record(for: id)
                return (record["decision"] as? String).flatMap(JoinDecision.init(rawValue:))
            } catch let error as CKError where error.code == .unknownItem {
                return nil
            }
        }
    }

    public func withdrawJoinRequest(name: String) async throws {
        try await run {
            do {
                _ = try await container.publicCloudDatabase.deleteRecord(withID: CKRecord.ID(recordName: name))
            } catch let error as CKError where error.code == .unknownItem {
                return
            }
        }
    }

    // MARK: Push

    public func subscribeToChanges() async throws {
        try await run {
            let subscriptions: [(scope: CloudZone.Scope, id: String)] = [
                (.owned, Self.privateSubscription),
                (.joined, Self.sharedSubscription),
            ]
            for (scope, id) in subscriptions {
                let subscription = CKDatabaseSubscription(subscriptionID: id)
                let info = CKSubscription.NotificationInfo()
                info.shouldSendContentAvailable = true
                subscription.notificationInfo = info
                let result = try await database(scope).modifySubscriptions(saving: [subscription], deleting: [])
                for (_, outcome) in result.saveResults {
                    if case .failure(let error) = outcome { throw error }
                }
            }
        }
    }

    // MARK: Hilfen

    private func existingShare(_ id: CKRecord.ID, in database: CKDatabase) async throws -> CKShare? {
        do {
            return try await database.record(for: id) as? CKShare
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
            return nil
        }
    }

    /// Führt einen CloudKit-Aufruf aus und übersetzt Fehler in `CloudStoreError`.
    private func run<Value>(_ operation: () async throws -> Value) async throws -> Value {
        do {
            return try await operation()
        } catch let error as CloudStoreError {
            throw error
        } catch {
            throw Self.translate(error)
        }
    }

    /// Bei atomaren Paketen melden alle übrigen Datensätze nur „Paket gescheitert“;
    /// maßgeblich ist der eigentliche Fehler.
    private static func firstRealError<Values: Sequence>(_ outcomes: Values) -> (any Error)? where Values.Element == Result<CKRecord, any Error> {
        var fallback: (any Error)?
        for outcome in outcomes {
            guard case .failure(let error) = outcome else { continue }
            if let ckError = error as? CKError, ckError.code == .batchRequestFailed {
                fallback = fallback ?? error
                continue
            }
            return error
        }
        return fallback
    }

    private static func innerError(of error: CKError) -> CKError? {
        guard let partial = error.partialErrorsByItemID else { return nil }
        return partial.values.compactMap { $0 as? CKError }.first { $0.code != .batchRequestFailed }
    }

    static func translate(_ error: any Error) -> CloudStoreError {
        guard let ckError = error as? CKError else {
            return (error as? URLError) != nil ? .network : .other(error.localizedDescription)
        }
        switch ckError.code {
        case .partialFailure:
            return innerError(of: ckError).map(translate) ?? .other(ckError.localizedDescription)
        case .notAuthenticated, .managedAccountRestricted:
            return .notSignedIn
        case .networkUnavailable, .networkFailure:
            return .network
        case .serviceUnavailable, .requestRateLimited, .zoneBusy:
            return .retry(after: ckError.retryAfterSeconds ?? 5)
        case .accountTemporarilyUnavailable:
            return .retry(after: ckError.retryAfterSeconds ?? 30)
        case .zoneNotFound:
            return ckError.userInfo[CKErrorUserDidResetEncryptedDataKey] != nil ? .keyReset : .zoneMissing
        case .userDeletedZone:
            return .zoneMissing
        case .changeTokenExpired:
            return .tokenExpired
        case .permissionFailure, .participantMayNeedVerification:
            return .permissionDenied
        case .quotaExceeded:
            return .quotaExceeded
        case .limitExceeded:
            return .batchTooLarge
        case .serverRecordChanged:
            return .conflict
        case .unknownItem:
            return .zoneMissing
        case .alreadyShared, .tooManyParticipants:
            return .conflict
        default:
            return .other(ckError.localizedDescription)
        }
    }

    private static func encodeToken(_ token: CKServerChangeToken) throws -> Data {
        try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
    }

    private static func decodeToken(_ data: Data) throws -> CKServerChangeToken? {
        do {
            return try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
        } catch {
            // Unlesbarer Stand: wie abgelaufen behandeln (von vorn, ohne Verlust).
            throw CloudStoreError.tokenExpired
        }
    }
}
