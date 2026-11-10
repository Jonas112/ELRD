import Foundation
#if canImport(CoreNFC)
import CoreNFC
#endif

/// Patientenanhängekarte mit NFC-Chip lesen (Schritt 110). Funktioniert nur auf
/// Geräten mit NFC-Leser (iPhone); auf dem iPad ist `isAvailable` falsch.
///
/// Kartennummer = Text- oder Link-Eintrag (NDEF) auf dem Chip; ohne solchen Eintrag
/// die Seriennummer des Chips (hexadezimal) – so lässt sich jede Karte zuordnen.
@MainActor
final class NFCCardReader: NSObject {
    enum ReadError: LocalizedError {
        case unavailable
        case cancelled
        case unreadable

        var errorDescription: String? {
            switch self {
            case .unavailable: "Dieses Gerät kann keine NFC-Karten lesen."
            case .cancelled: nil
            case .unreadable: "Die Karte ließ sich nicht lesen. Bitte ruhig an die Oberkante des iPhones halten."
            }
        }
    }

    static var isAvailable: Bool {
        #if canImport(CoreNFC)
        NFCTagReaderSession.readingAvailable
        #else
        false
        #endif
    }

    /// Text eines NDEF-Eintrags: Text-Eintrag, sonst Link (letzter Pfadteil oder ganze Adresse).
    nonisolated static func cardText(texts: [String], uris: [URL]) -> String? {
        if let text = texts.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }).first(where: { !$0.isEmpty }) {
            return text
        }
        if let uri = uris.first {
            let last = uri.lastPathComponent
            return last.isEmpty || last == "/" ? uri.absoluteString : last
        }
        return nil
    }

    /// Seriennummer als Hex-Text, z. B. „04A1B2C3D4E5F6“.
    nonisolated static func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined()
    }

    #if canImport(CoreNFC)
    private var session: NFCTagReaderSession?
    private var completion: ((Result<String, ReadError>) -> Void)?

    func read(completion: @escaping (Result<String, ReadError>) -> Void) {
        guard Self.isAvailable, let session = NFCTagReaderSession(pollingOption: [.iso14443, .iso15693], delegate: self, queue: .main) else {
            completion(.failure(.unavailable))
            return
        }
        self.completion = completion
        self.session = session
        session.alertMessage = "Anhängekarte an die Oberkante des iPhones halten."
        session.begin()
    }

    fileprivate func finish(_ result: Result<String, ReadError>) {
        let completion = completion
        self.completion = nil
        session = nil
        completion?(result)
    }
    #else
    func read(completion: @escaping (Result<String, ReadError>) -> Void) {
        completion(.failure(.unavailable))
    }
    #endif
}

#if canImport(CoreNFC)
extension NFCCardReader: NFCTagReaderSessionDelegate {
    nonisolated func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}

    nonisolated func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: any Error) {
        let cancelled = (error as? NFCReaderError)?.code == .readerSessionInvalidationErrorUserCanceled
            || (error as? NFCReaderError)?.code == .readerSessionInvalidationErrorFirstNDEFTagRead
        Task { @MainActor in
            // Nach Erfolg ist `completion` schon leer; dann passiert hier nichts.
            self.finish(.failure(cancelled ? .cancelled : .unreadable))
        }
    }

    nonisolated func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard let tag = tags.first else { return }
        let ndef: (any NFCNDEFTag)?
        let serial: Data?
        switch tag {
        case let .miFare(chip): ndef = chip; serial = chip.identifier
        case let .iso7816(chip): ndef = chip; serial = chip.identifier
        case let .iso15693(chip): ndef = chip; serial = chip.identifier
        case let .feliCa(chip): ndef = chip; serial = chip.currentIDm
        @unknown default: ndef = nil; serial = nil
        }
        session.connect(to: tag) { error in
            guard error == nil else {
                session.invalidate(errorMessage: "Karte nicht erkannt – bitte erneut versuchen.")
                return
            }
            let fallback = serial.map(NFCCardReader.hex)
            guard let ndef else {
                self.complete(session, text: fallback)
                return
            }
            ndef.readNDEF { message, _ in
                let records = message?.records ?? []
                let texts = records.compactMap { $0.wellKnownTypeTextPayload().0 }
                let uris = records.compactMap { $0.wellKnownTypeURIPayload() }
                self.complete(session, text: NFCCardReader.cardText(texts: texts, uris: uris) ?? fallback)
            }
        }
    }

    private nonisolated func complete(_ session: NFCTagReaderSession, text: String?) {
        guard let text, !text.isEmpty else {
            session.invalidate(errorMessage: "Auf der Karte steht keine Nummer.")
            return
        }
        session.alertMessage = "Karte gelesen."
        session.invalidate()
        Task { @MainActor in self.finish(.success(text)) }
    }
}
#endif
