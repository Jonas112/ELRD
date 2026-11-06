import Foundation
import Testing
@testable import ELRDDomain
@testable import ELRDPersistence

@Suite("Anhänge als Dateien")
struct AttachmentFileStoreTests {
    @Test func savedFileIsFoundAndVerified() throws {
        let store = AttachmentFileStore.temporary()
        let data = Data("Zeichnung".utf8)
        let file = try store.save(data, kind: .drawing, createdAt: Date(timeIntervalSince1970: 0), pixelWidth: 4, pixelHeight: 2)
        #expect(file.kind == .drawing)
        #expect(file.byteCount == data.count)
        #expect(file.hasValidChecksum)
        #expect(file.fileName.hasSuffix(".png"))
        #expect(store.data(for: file) == data)
        #expect(store.isIntact(file))
        // SHA-256 von „abc“ (bekannter Prüfwert).
        #expect(AttachmentFileStore.sha256(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func missingOrChangedFileIsNotIntact() throws {
        let store = AttachmentFileStore.temporary()
        let file = try store.save(Data([1, 2, 3]), kind: .photo, createdAt: Date())
        try Data([9]).write(to: store.url(for: file))
        #expect(!store.isIntact(file), "Inhalt passt nicht zur Prüfsumme")
        try FileManager.default.removeItem(at: store.url(for: file))
        #expect(store.data(for: file) == nil)
    }
}
