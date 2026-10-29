import Foundation
import Testing
@testable import ELRDDomain
@testable import ELRDPersistence

@Suite("Dokumente")
@MainActor
struct DocumentRepositoryTests {
    func make(_ kind: RepositoryKind) throws -> any DocumentRepository {
        switch kind {
        case .swiftData: SwiftDataRepository(container: try PersistenceStore.makeInMemoryContainer())
        case .inMemory: InMemoryRepository()
        }
    }

    @Test(arguments: RepositoryKind.allCases)
    func saveLoadReplaceDelete(kind: RepositoryKind) throws {
        let repo = try make(kind)
        let now = Date(timeIntervalSince1970: 1_792_000_000)
        #expect(try repo.document(MasterDataSet.self, key: .masterData) == nil)

        var set = MasterDataSet(units: [MasterUnit(callsign: "RTW 1", type: .rtw)], revision: 1)
        try repo.saveDocument(set, key: .masterData, at: now)
        #expect(try repo.document(MasterDataSet.self, key: .masterData) == set)

        set.units.append(MasterUnit(callsign: "NEF 1", type: .nef))
        set.revision = 2
        try repo.saveDocument(set, key: .masterData, at: now.addingTimeInterval(60))
        #expect(try repo.document(MasterDataSet.self, key: .masterData)?.units.count == 2)

        try repo.deleteDocument(key: .masterData)
        #expect(try repo.document(MasterDataSet.self, key: .masterData) == nil)
    }
}
