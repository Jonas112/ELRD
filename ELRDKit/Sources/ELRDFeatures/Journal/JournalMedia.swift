import SwiftUI
import UIKit
import ImageIO
import UniformTypeIdentifiers
import AVFoundation
import ELRDDomain
import ELRDPersistence

// MARK: - Fotos

/// Fotos verkleinern (längste Seite 2048 px, Ausrichtung angewendet) und als JPEG
/// speichern – Originale aus der Kamera wären 10 MB und mehr.
enum PhotoImport {
    static let maxPixel = 2048

    /// JPEG aus beliebigen Bilddaten (HEIC, JPEG, PNG).
    static func jpeg(from data: Data, maxPixel: Int = maxPixel) -> (data: Data, width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return encode(image)
    }

    static func jpeg(from image: UIImage, maxPixel: Int = maxPixel) -> (data: Data, width: Int, height: Int)? {
        guard let data = image.jpegData(compressionQuality: 0.95) else { return nil }
        return jpeg(from: data, maxPixel: maxPixel)
    }

    private static func encode(_ image: CGImage) -> (data: Data, width: Int, height: Int)? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (output as Data, image.width, image.height)
    }

    /// Speichert ein verkleinertes Foto in der Ablage. Der Aufnahmeort kommt aus den
    /// GPS-Daten des Bildes, sonst aus `fallback` (Schritt 111).
    static func save(_ data: Data, in store: AttachmentFileStore, at date: Date = Date(), fallback: GeoCoordinate? = nil) throws -> FileAttachment? {
        guard let jpeg = jpeg(from: data) else { return nil }
        return try store.save(
            jpeg.data, kind: .photo, createdAt: date, pixelWidth: jpeg.width, pixelHeight: jpeg.height,
            coordinate: coordinate(from: data) ?? fallback
        )
    }

    /// Aufnahmeort aus den GPS-Metadaten (EXIF) eines Bildes.
    static func coordinate(from data: Data) -> GeoCoordinate? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] else { return nil }
        return coordinate(gps: gps)
    }

    static func coordinate(gps: [CFString: Any]) -> GeoCoordinate? {
        guard let latitude = (gps[kCGImagePropertyGPSLatitude] as? NSNumber)?.doubleValue,
              let longitude = (gps[kCGImagePropertyGPSLongitude] as? NSNumber)?.doubleValue else { return nil }
        let south = (gps[kCGImagePropertyGPSLatitudeRef] as? String)?.uppercased() == "S"
        let west = (gps[kCGImagePropertyGPSLongitudeRef] as? String)?.uppercased() == "W"
        return GeoCoordinate(latitude: south ? -latitude : latitude, longitude: west ? -longitude : longitude)
    }
}

/// Kamera (UIKit), da SwiftUI unter iPadOS 17 keine eigene Kameraansicht hat.
struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    /// Schließt die Kamera (aufrufende Ansicht setzt ihren Zustand zurück).
    let onFinish: () -> Void

    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker

        init(parent: CameraPicker) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.onFinish()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onFinish()
        }
    }
}

// MARK: - Sprachnotizen

/// Aufnahme als AAC (m4a, Sprachqualität). Fragt beim ersten Mal nach dem Mikrofon.
@MainActor
final class VoiceRecorder: NSObject, ObservableObject {
    enum Phase: Equatable { case idle, recording(since: Date), denied, failed(String) }

    @Published private(set) var phase: Phase = .idle
    private var recorder: AVAudioRecorder?
    private var fileURL: URL?

    var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    func start() async {
        guard !isRecording else { return }
        let allowed = await AVAudioApplication.requestRecordPermission()
        guard allowed else {
            phase = .denied
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker])
            try session.setActive(true)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("aufnahme-\(UUID().uuidString).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 22_050,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            ]
            let created = try AVAudioRecorder(url: url, settings: settings)
            guard created.record() else {
                phase = .failed("Die Aufnahme ließ sich nicht starten.")
                return
            }
            recorder = created
            fileURL = url
            phase = .recording(since: Date())
        } catch {
            phase = .failed(ErrorText.message(for: error))
        }
    }

    /// Beendet die Aufnahme und liefert Datei und Dauer (`nil` bei unter 1 s).
    func stop() -> (data: Data, duration: TimeInterval)? {
        guard let active = recorder, let url = fileURL else { return nil }
        let duration = active.currentTime
        active.stop()
        recorder = nil
        fileURL = nil
        phase = .idle
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        defer { try? FileManager.default.removeItem(at: url) }
        guard duration >= 1, let data = try? Data(contentsOf: url) else { return nil }
        return (data, duration)
    }

    func cancel() {
        recorder?.stop()
        recorder?.deleteRecording()
        recorder = nil
        fileURL = nil
        phase = .idle
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// Wiedergabe von Sprachnotizen; immer nur eine gleichzeitig.
@MainActor
final class VoicePlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var playingID: AttachmentID?
    private var player: AVAudioPlayer?

    func toggle(_ file: FileAttachment, in store: AttachmentFileStore) {
        if playingID == file.id {
            stop()
            return
        }
        stop()
        guard let data = store.data(for: file) else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            let created = try AVAudioPlayer(data: data)
            created.delegate = self
            created.play()
            player = created
            playingID = file.id
        } catch {
            playingID = nil
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playingID = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        MainActor.assumeIsolated {
            self.player = nil
            self.playingID = nil
        }
    }
}

/// „1:05“ für Aufnahmedauer.
enum DurationText {
    static func string(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds.rounded()), 0)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
