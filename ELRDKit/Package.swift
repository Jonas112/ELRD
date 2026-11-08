// swift-tools-version: 6.0
import PackageDescription

/// Gemeinsame Compiler-Einstellungen: Swift-5-Sprachmodus mit vollständiger
/// Concurrency-Prüfung (siehe docs/ARCHITEKTUR.md).
let commonSettings: [SwiftSetting] = [
    .enableUpcomingFeature("StrictConcurrency"),
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "ELRDKit",
    defaultLocalization: "de",
    platforms: [
        .iOS(.v17),
    ],
    products: [
        .library(
            name: "ELRDKit",
            targets: [
                "ELRDDomain",
                "ELRDPersistence",
                "ELRDSync",
                "ELRDStore",
                "ELRDAuth",
                "ELRDEntitlements",
                "ELRDReports",
                "ELRDStammdaten",
                "ELRDCloud",
                "ELRDLiveActivity",
                "ELRDFeatures",
            ]
        ),
        // Für das Widget-Ziel der App (Live Activity, Schritt 90).
        .library(name: "ELRDLiveActivity", targets: ["ELRDLiveActivity"]),
    ],
    targets: [
        // Reine Werttypen und Fachregeln. Keine Abhängigkeiten.
        .target(name: "ELRDDomain", swiftSettings: commonSettings),

        // SwiftData-Modelle, Mapping, Repositories.
        .target(name: "ELRDPersistence", dependencies: ["ELRDDomain", "ELRDSync"], swiftSettings: commonSettings),

        // Änderungsjournal und Sync-Protokoll.
        .target(name: "ELRDSync", dependencies: ["ELRDDomain"], swiftSettings: commonSettings),

        // Commands, MissionStore, Vorschaudaten (ohne SwiftUI, testbar).
        .target(name: "ELRDStore", dependencies: ["ELRDDomain", "ELRDSync", "ELRDPersistence", "ELRDEntitlements"], swiftSettings: commonSettings),

        // Benutzer, Passwort-Hashing, Keychain, AuthProvider.
        .target(name: "ELRDAuth", dependencies: ["ELRDDomain", "ELRDPersistence"], swiftSettings: commonSettings),

        // Freischaltungen / Abo-Status.
        .target(name: "ELRDEntitlements", swiftSettings: commonSettings),

        // PDF-Engine und Berichtsvorlagen.
        .target(name: "ELRDReports", dependencies: ["ELRDDomain"], swiftSettings: commonSettings),

        // Stammdatenmodell und CSV-Regionsimport.
        .target(
            name: "ELRDStammdaten",
            dependencies: ["ELRDDomain"],
            resources: [.copy("Daten")],
            swiftSettings: commonSettings
        ),

        // Abgleich über iCloud (CloudKit, geteilte Zonen je Einsatz).
        .target(name: "ELRDCloud", dependencies: ["ELRDDomain", "ELRDSync", "ELRDPersistence", "ELRDStore"], swiftSettings: commonSettings),

        // Live Activity (Sperrbildschirm, Dynamic Island) – von App und Widget-Ziel genutzt.
        .target(name: "ELRDLiveActivity", swiftSettings: commonSettings),

        // SwiftUI-Oberflächen und Designsystem.
        .target(
            name: "ELRDFeatures",
            dependencies: [
                "ELRDDomain",
                "ELRDPersistence",
                "ELRDSync",
                "ELRDStore",
                "ELRDAuth",
                "ELRDEntitlements",
                "ELRDReports",
                "ELRDStammdaten",
                "ELRDCloud",
                "ELRDLiveActivity",
            ],
            resources: [.copy("Rechtliches")],
            swiftSettings: commonSettings
        ),

        .testTarget(name: "ELRDDomainTests", dependencies: ["ELRDDomain"], swiftSettings: commonSettings),
        .testTarget(name: "ELRDSyncTests", dependencies: ["ELRDSync", "ELRDDomain"], swiftSettings: commonSettings),
        .testTarget(name: "ELRDPersistenceTests", dependencies: ["ELRDPersistence", "ELRDSync", "ELRDDomain"], swiftSettings: commonSettings),
        .testTarget(name: "ELRDStammdatenTests", dependencies: ["ELRDStammdaten", "ELRDDomain"], swiftSettings: commonSettings),
        .testTarget(name: "ELRDAuthTests", dependencies: ["ELRDAuth", "ELRDPersistence", "ELRDDomain"], swiftSettings: commonSettings),
        .testTarget(name: "ELRDEntitlementsTests", dependencies: ["ELRDEntitlements"], swiftSettings: commonSettings),
        .testTarget(name: "ELRDFeaturesTests", dependencies: ["ELRDFeatures", "ELRDStore", "ELRDDomain"], swiftSettings: commonSettings),
        .testTarget(name: "ELRDReportsTests", dependencies: ["ELRDReports", "ELRDStore", "ELRDDomain", "ELRDPersistence", "ELRDSync"], swiftSettings: commonSettings),
        .testTarget(name: "ELRDCloudTests", dependencies: ["ELRDCloud", "ELRDStore", "ELRDPersistence", "ELRDSync", "ELRDDomain"], swiftSettings: commonSettings),
        .testTarget(name: "ELRDStoreTests", dependencies: ["ELRDStore", "ELRDPersistence", "ELRDSync", "ELRDDomain", "ELRDEntitlements"], swiftSettings: commonSettings),
    ],
    swiftLanguageModes: [.v5]
)
