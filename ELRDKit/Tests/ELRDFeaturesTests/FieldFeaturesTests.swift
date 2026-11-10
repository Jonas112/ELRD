import Foundation
import ImageIO
import Testing
@testable import ELRDDomain
@testable import ELRDFeatures

@Suite("NFC, Fotos mit Ort, Darstellung, taktische Zeichen (Schritte 110–114)")
@MainActor
struct FieldFeaturesTests {
    // MARK: 110 NFC

    @Test func nfcTextPrefersTextRecord() {
        #expect(NFCCardReader.cardText(texts: ["  PAK-0815 "], uris: []) == "PAK-0815")
        #expect(NFCCardReader.cardText(texts: [""], uris: [URL(string: "https://karte.example/pak/4711")!]) == "4711")
        #expect(NFCCardReader.cardText(texts: [], uris: []) == nil)
        #expect(NFCCardReader.hex(Data([0x04, 0xA1, 0x0F])) == "04A10F")
    }

    // MARK: 111 Fotos mit Ort

    @Test func gpsMetadataBecomesCoordinate() {
        let gps: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: 50.1,
            kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 10.18,
            kCGImagePropertyGPSLongitudeRef: "E",
        ]
        let coordinate = PhotoImport.coordinate(gps: gps)
        #expect(coordinate?.latitude == 50.1)
        #expect(coordinate?.longitude == 10.18)
        var west = gps
        west[kCGImagePropertyGPSLongitudeRef] = "W"
        west[kCGImagePropertyGPSLatitudeRef] = "S"
        #expect(PhotoImport.coordinate(gps: west)?.longitude == -10.18)
        #expect(PhotoImport.coordinate(gps: west)?.latitude == -50.1)
        #expect(PhotoImport.coordinate(gps: [:]) == nil)
    }

    // MARK: 113 Darstellung

    @Test func gloveModeEnlargesTouchTargets() {
        var settings = AppSettings()
        DisplayMode.shared.apply(settings)
        #expect(TouchTarget.minimum == 44)
        settings.gloveMode = true
        DisplayMode.shared.apply(settings)
        #expect(TouchTarget.minimum > 55)
        #expect(TouchTarget.large > TouchTarget.comfortable)
        settings.gloveMode = false
        DisplayMode.shared.apply(settings)
        #expect(TouchTarget.comfortable == 56)
    }

    @Test func displaySettingsDecodeWithDefaults() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(!settings.gloveMode)
        #expect(!settings.nightMode)
        #expect(settings.reminders.situationSnapshotMinutes == 0)
    }

    // MARK: 114 Taktische Zeichen

    @Test func everyPresetRenders() {
        for preset in TacticalSignPreset.all {
            let image = TacticalSignRenderer.image(for: preset.sign, height: 40)
            #expect(image.size.height >= 40, "\(preset.id)")
            #expect(image.size.width > 20, "\(preset.id)")
        }
    }
}
