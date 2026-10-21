import Foundation
import SwiftData

/// Erzeugt den SwiftData-Container der App.
public enum PersistenceStore {
    /// Speicherort der Datenbank: `Application Support/ELRD/ELRD.store`.
    public static func defaultStoreURL(fileManager: FileManager = .default) throws -> URL {
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = support.appendingPathComponent("ELRD", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("ELRD.store")
    }

    /// Container für die App (auf dem Gerät gespeichert, mit Dateischutz).
    public static func makeContainer(storeURL: URL? = nil) throws -> ModelContainer {
        let url = try storeURL ?? defaultStoreURL()
        let configuration = ModelConfiguration(
            "ELRD",
            schema: Schema(versionedSchema: ELRDSchemaV1.self),
            url: url,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(
            for: Schema(versionedSchema: ELRDSchemaV1.self),
            migrationPlan: ELRDMigrationPlan.self,
            configurations: [configuration]
        )
        protectStoreFiles(at: url)
        return container
    }

    /// Container nur im Arbeitsspeicher (Tests, SwiftUI-Vorschauen).
    public static func makeInMemoryContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(
            schema: Schema(versionedSchema: ELRDSchemaV1.self),
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: Schema(versionedSchema: ELRDSchemaV1.self),
            migrationPlan: ELRDMigrationPlan.self,
            configurations: [configuration]
        )
    }

    /// Datenschutz (DSGVO): Datenbank-Dateien sind nach dem Neustart bis zur ersten
    /// Entsperrung verschlüsselt. „complete“ wäre strenger, würde aber Speichern bei
    /// gesperrtem Gerät verhindern – im Einsatz nicht praktikabel.
    static func protectStoreFiles(at url: URL, fileManager: FileManager = .default) {
        #if os(iOS)
        let candidates = [url.path, url.path + "-wal", url.path + "-shm"]
        for path in candidates where fileManager.fileExists(atPath: path) {
            try? fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: path
            )
        }
        #endif
    }
}
