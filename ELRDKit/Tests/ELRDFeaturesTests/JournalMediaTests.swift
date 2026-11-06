import Foundation
import Testing
import UIKit
@testable import ELRDFeatures

@Suite("Tagebuch: Fotos verkleinern")
@MainActor
struct JournalMediaTests {
    @Test func largePhotoIsScaledDownToJPEG() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4000, height: 3000), format: format).image { context in
            UIColor.systemRed.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4000, height: 3000))
        }
        let result = try #require(PhotoImport.jpeg(from: image))
        #expect(max(result.width, result.height) == PhotoImport.maxPixel)
        #expect(result.width > result.height, "Querformat bleibt")
        #expect(result.data.starts(with: [0xFF, 0xD8]), "JPEG")
    }

    @Test func durationIsMinutesAndSeconds() {
        #expect(DurationText.string(0) == "0:00")
        #expect(DurationText.string(65.4) == "1:05")
        #expect(DurationText.string(600) == "10:00")
    }
}
