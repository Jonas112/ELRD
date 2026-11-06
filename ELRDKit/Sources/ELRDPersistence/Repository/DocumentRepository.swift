import Foundation
import SwiftData
import ELRDDomain

/// Schlüssel gespeicherter Dokumente. Rohwerte sind Teil des Speicherformats.
public struct DocumentKey: Hashable, Sendable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// Stammdaten des Geräts (`MasterDataSet`).
    public static let masterData = DocumentKey(rawValue: "masterData")
    /// Textbausteine des Tagebuchs (`JournalTemplateSet`).
    public static let journalTemplates = DocumentKey(rawValue: "journalTemplates")
}

/// Speichert einzelne, als Ganzes behandelte Dokumente (Stammdaten, später Einstellungen).
@MainActor
public protocol DocumentRepository: AnyObject {
    func document<Value: Decodable>(_ type: Value.Type, key: DocumentKey) throws -> Value?
    func saveDocument<Value: Encodable>(_ value: Value, key: DocumentKey, at date: Date) throws
    func deleteDocument(key: DocumentKey) throws
}

extension SwiftDataRepository: DocumentRepository {
    public func document<Value: Decodable>(_ type: Value.Type, key: DocumentKey) throws -> Value? {
        guard let record = try documentRecord(key) else { return nil }
        return try JSONDecoder().decode(type, from: record.payload)
    }

    public func saveDocument<Value: Encodable>(_ value: Value, key: DocumentKey, at date: Date) throws {
        let payload = try RecordMapping.makeEncoder().encode(value)
        do {
            if let record = try documentRecord(key) {
                record.payload = payload
                record.updatedAt = date
            } else {
                modelContext.insert(DocumentRecord(key: key.rawValue, updatedAt: date, payload: payload))
            }
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    public func deleteDocument(key: DocumentKey) throws {
        let name = key.rawValue
        try modelContext.delete(model: DocumentRecord.self, where: #Predicate { $0.key == name })
        try modelContext.save()
    }

    private func documentRecord(_ key: DocumentKey) throws -> DocumentRecord? {
        let name = key.rawValue
        var descriptor = FetchDescriptor<DocumentRecord>(predicate: #Predicate { $0.key == name })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}

extension InMemoryRepository: DocumentRepository {
    public func document<Value: Decodable>(_ type: Value.Type, key: DocumentKey) throws -> Value? {
        guard let data = documents[key] else { return nil }
        return try JSONDecoder().decode(type, from: data)
    }

    public func saveDocument<Value: Encodable>(_ value: Value, key: DocumentKey, at date: Date) throws {
        documents[key] = try RecordMapping.makeEncoder().encode(value)
    }

    public func deleteDocument(key: DocumentKey) throws {
        documents[key] = nil
    }
}
