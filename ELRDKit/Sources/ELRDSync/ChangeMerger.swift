import Foundation

/// Führt Änderungsereignisse feldweise zusammen („letzter Schreiber gewinnt“
/// je Feld bzw. je Listenelement, geordnet nach HLC-Zeitstempel).
///
/// Eigenschaften (durch Tests abgesichert):
/// - Reihenfolge-unabhängig: Gleiche Ereignisse in beliebiger Reihenfolge
///   ergeben denselben Stand.
/// - Idempotent: Ein doppelt empfangenes Ereignis ändert nichts.
/// - Gleichzeitige Änderungen verschiedener Felder bleiben beide erhalten.
public struct MergeState: Hashable, Codable, Sendable {
    /// Felder der Entität als JSON-Objekt.
    public private(set) var fields: [String: JSONValue]
    /// Zeitstempel der zuletzt angewendeten Änderung je Konfliktschlüssel.
    public private(set) var clocks: [String: HybridTimestamp]
    /// Für Listenelemente: Kennungen in Einfüge-Reihenfolge, damit die Reihenfolge
    /// auf allen Geräten gleich ist (sortiert nach Zeitstempel des ersten Einfügens).
    private var elementOrder: [String: [String: HybridTimestamp]]

    public init(fields: [String: JSONValue] = [:]) {
        self.fields = fields
        self.clocks = [:]
        self.elementOrder = [:]
    }

    /// Wendet die Feldänderungen eines Ereignisses an.
    public mutating func apply(_ event: ChangeEvent) {
        for change in event.changes {
            apply(change, at: event.timestamp)
        }
    }

    mutating func apply(_ change: FieldChange, at timestamp: HybridTimestamp) {
        // Listen mit Kennungen werden nie als Ganzes überschrieben, sondern elementweise
        // ergänzt. Sonst könnte z. B. die leere Verletzungsliste aus dem Anlegen eine
        // später auf einem anderen Gerät ergänzte Verletzung wieder löschen.
        if case let .set(field, .array(elements)) = change, elements.allSatisfy({ $0.elementID != nil }) {
            if fields[field] == nil { fields[field] = .array([]) }
            for element in elements {
                if let id = element.elementID {
                    apply(.upsertElement(field: field, elementID: id, value: element), at: timestamp)
                }
            }
            return
        }

        // Position eines Listenelements = frühestes bekanntes Einfügen. Wird auch bei
        // verworfenen (älteren) Änderungen erfasst, sonst hinge die Reihenfolge davon ab,
        // in welcher Reihenfolge die Ereignisse eintreffen.
        if case let .upsertElement(field, elementID, _) = change {
            var order = elementOrder[field, default: [:]]
            order[elementID] = min(order[elementID] ?? timestamp, timestamp)
            elementOrder[field] = order
        }

        let key = change.conflictKey
        if let current = clocks[key], current >= timestamp {
            // Ältere Änderung: Wert bleibt, aber die Listenreihenfolge kann sich geändert haben.
            if case let .upsertElement(field, _, _) = change, fields[field] != nil {
                writeElements(currentElements(field), field: field)
            }
            return
        }
        clocks[key] = timestamp

        switch change {
        case let .set(field, value):
            fields[field] = value

        case let .upsertElement(field, elementID, value):
            var elements = currentElements(field)
            elements[elementID] = value
            writeElements(elements, field: field)

        case let .removeElement(field, elementID):
            var elements = currentElements(field)
            elements[elementID] = nil
            writeElements(elements, field: field)
        }
    }

    private func currentElements(_ field: String) -> [String: JSONValue] {
        guard case let .array(elements)? = fields[field] else { return [:] }
        var result: [String: JSONValue] = [:]
        for element in elements {
            if let id = element.elementID { result[id] = element }
        }
        return result
    }

    private mutating func writeElements(_ elements: [String: JSONValue], field: String) {
        let order = elementOrder[field, default: [:]]
        let sorted = elements.sorted { lhs, rhs in
            switch (order[lhs.key], order[rhs.key]) {
            case let (l?, r?): l < r
            case (.some, nil): false
            case (nil, .some): true
            case (nil, nil): lhs.key < rhs.key
            }
        }
        fields[field] = .array(sorted.map(\.value))
    }

    /// Wandelt den zusammengeführten Stand in den Swift-Typ um.
    /// `metadata` muss der Aufrufer ergänzen (stammt nicht aus Feldänderungen).
    public func decode<T: Decodable>(_ type: T.Type, metadata: JSONValue) throws -> T {
        var object = fields
        object["metadata"] = metadata
        return try JSONValueCoder.decode(T.self, from: .object(object))
    }
}
