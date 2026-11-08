import SwiftUI
import Speech
import AVFoundation

/// Diktat (Schritt 74): Spracherkennung auf dem Gerät, Text wird angehängt.
///
/// Erkennt nur auf dem Gerät (`requiresOnDeviceRecognition`) – Sprache verlässt
/// das iPad nicht. Geht das nicht (Gerät/Sprache ohne Offline-Modell), bleibt der
/// Knopf ausgeblendet statt Audio an Apple zu schicken.
@MainActor
@Observable
final class Dictation {
    enum Phase: Equatable {
        case idle
        case listening
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// Bisher erkannter Text der laufenden Aufnahme.
    private(set) var partial = ""

    @ObservationIgnored private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "de-DE"))
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var onFinish: ((String) -> Void)?

    /// Ob Diktat auf diesem Gerät ohne Internet möglich ist.
    var isSupported: Bool {
        guard let recognizer else { return false }
        return recognizer.supportsOnDeviceRecognition
    }

    func start(onFinish: @escaping (String) -> Void) async {
        guard phase != .listening else { return }
        guard await Self.authorize() else {
            phase = .failed("Keine Berechtigung für Spracherkennung oder Mikrofon (Einstellungen → ELRD).")
            return
        }
        guard let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            phase = .failed("Diktat ist auf diesem Gerät gerade nicht verfügbar.")
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = true
            request.addsPunctuation = true
            self.request = request

            let input = engine.inputNode
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { [request] buffer, _ in
                request.append(buffer)
            }
            engine.prepare()
            try engine.start()
            partial = ""
            self.onFinish = onFinish
            phase = .listening

            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let isFinal = result?.isFinal ?? false
                Task { @MainActor in
                    guard let self else { return }
                    if let text { self.partial = text }
                    if isFinal || error != nil { self.finish() }
                }
            }
        } catch {
            stopAudio()
            phase = .failed("Aufnahme nicht möglich.")
        }
    }

    /// Beendet das Diktat und übergibt den Text.
    func stop() {
        guard phase == .listening else { return }
        request?.endAudio()
        finish()
    }

    private func finish() {
        guard phase == .listening else { return }
        stopAudio()
        phase = .idle
        let text = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        partial = ""
        let callback = onFinish
        onFinish = nil
        if !text.isEmpty { callback?(text) }
    }

    private func stopAudio() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        task?.cancel()
        task = nil
        request = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private static func authorize() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }
}

/// Mikrofon-Knopf neben einem Textfeld: Tippen startet, erneut Tippen fügt den Text an.
struct DictationButton: View {
    @Binding var text: String
    @State private var dictation = Dictation()

    var body: some View {
        if dictation.isSupported {
            Button(action: toggle) {
                Image(systemName: dictation.phase == .listening ? "stop.circle.fill" : "mic.fill")
                    .font(.title2)
                    .foregroundStyle(dictation.phase == .listening ? Color.red : Color.accentColor)
                    .frame(width: TouchTarget.comfortable, height: TouchTarget.comfortable)
                    .symbolEffect(.pulse, isActive: dictation.phase == .listening)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(dictation.phase == .listening ? "Diktat beenden" : "Diktieren")
            .popover(isPresented: Binding(get: { dictation.phase == .listening || isFailed }, set: { if !$0 { dictation.stop() } })) {
                Text(popoverText)
                    .font(.title3)
                    .padding(Spacing.l)
                    .frame(minWidth: 280, maxWidth: 420, alignment: .leading)
                    .presentationCompactAdaptation(.popover)
            }
        }
    }

    private var isFailed: Bool {
        if case .failed = dictation.phase { return true }
        return false
    }

    private var popoverText: String {
        switch dictation.phase {
        case .listening: dictation.partial.isEmpty ? "Ich höre zu …" : dictation.partial
        case .failed(let message): message
        case .idle: ""
        }
    }

    private func toggle() {
        if dictation.phase == .listening {
            dictation.stop()
            return
        }
        Task {
            await dictation.start { spoken in
                let current = text.trimmingCharacters(in: .whitespacesAndNewlines)
                text = current.isEmpty ? spoken : current + " " + spoken
            }
        }
    }
}
