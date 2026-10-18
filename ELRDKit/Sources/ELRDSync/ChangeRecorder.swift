import Foundation
import ELRDDomain

/// Ermittelt aus altem und neuem Stand einer Entität das Änderungsereignis.
///
/// Wird ab Schritt 10 von der Command-Schicht bei jeder Änderung aufgerufen.
public enum ChangeRecorder {
    /// Felder, die nicht feldweise synchronisiert werden. Die Metadaten werden aus
    /// Operation, Zeitstempel und Autor des Ereignisses abgeleitet.
    static let excludedFields: Set<String> = ["metadata"]

    /// Erstellt ein Ereignis oder `nil`, wenn sich nichts geändert hat.
    /// - Parameters:
    ///   - old: Stand vorher; `nil` bei neu angelegten Entitäten.
    ///   - new: Stand nachher.
    public static func event<Entity: SyncEntity>(
        old: Entity?,
        new: Entity,
        clock: inout HybridLogicalClock,
        author: UserID?,
        now: Date
    ) throws -> ChangeEvent? {
        let operation = operation(old: old, new: new)
        let changes = try diff(old: old, new: new)
        guard operation != .update || !changes.isEmpty else { return nil }
        return ChangeEvent(
            missionID: new.missionID,
            entityType: Entity.syncEntityType,
            entityID: new.syncID,
            operation: operation,
            changes: changes,
            timestamp: clock.tick(now: now),
            authorID: author
        )
    }

    static func operation<Entity: SyncEntity>(old: Entity?, new: Entity) -> ChangeOperation {
        guard let old else { return .insert }
        switch (old.isDeleted, new.isDeleted) {
        case (false, true): return .delete
        case (true, false): return .restore
        default: return .update
        }
    }

    /// Feldweise Unterschiede. Listen, deren Elemente eine Kennung haben
    /// (Objekte mit `id` oder Texte wie UUIDs), werden elementweise verglichen.
    public static func diff<Entity: Encodable>(old: Entity?, new: Entity) throws -> [FieldChange] {
        let newFields = try fields(of: new)
        let oldFields = try old.map(fields(of:)) ?? [:]
        var changes: [FieldChange] = []

        for key in newFields.keys.union(oldFields.keys).sorted() where !excludedFields.contains(key) {
            let newValue = newFields[key] ?? .null
            let oldValue = oldFields[key] ?? .null
            guard newValue != oldValue else { continue }

            if let elementChanges = elementDiff(field: key, old: oldValue, new: newValue, isInsert: old == nil) {
                changes.append(contentsOf: elementChanges)
            } else {
                changes.append(.set(field: key, value: newValue))
            }
        }
        return changes
    }

    static func fields(of value: some Encodable) throws -> [String: JSONValue] {
        guard case let .object(object) = try JSONValueCoder.encode(value) else { return [:] }
        return object
    }

    /// Elementweiser Vergleich zweier Listen; `nil`, wenn die Listen nicht kennungsbasiert sind.
    static func elementDiff(field: String, old: JSONValue, new: JSONValue, isInsert: Bool) -> [FieldChange]? {
        let oldElements: [JSONValue]
        switch old {
        case let .array(elements): oldElements = elements
        case .null: oldElements = []
        default: return nil
        }
        guard case let .array(newElements) = new else { return nil }
        // Bei neuen Entitäten ohne Elemente genügt das Setzen der leeren Liste.
        if isInsert && newElements.isEmpty { return nil }

        let oldByID = keyed(oldElements)
        let newByID = keyed(newElements)
        guard let oldByID, let newByID else { return nil }

        var changes: [FieldChange] = []
        for element in newElements {
            guard let id = element.elementID else { continue }
            if oldByID[id] != element {
                changes.append(.upsertElement(field: field, elementID: id, value: element))
            }
        }
        for element in oldElements {
            guard let id = element.elementID, newByID[id] == nil else { continue }
            changes.append(.removeElement(field: field, elementID: id))
        }
        return changes
    }

    /// Ordnet Elemente nach Kennung; `nil`, wenn ein Element keine Kennung hat
    /// oder Kennungen doppelt vorkommen.
    private static func keyed(_ elements: [JSONValue]) -> [String: JSONValue]? {
        var result: [String: JSONValue] = [:]
        for element in elements {
            guard let id = element.elementID, result[id] == nil else { return nil }
            result[id] = element
        }
        return result
    }
}
