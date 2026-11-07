import Foundation
import SwiftUI
import Observation
import ELRDDomain
import ELRDPersistence

/// Felder mit ungesendetem Text, die einen App-Wechsel, eine Sperre oder einen
/// Absturz überleben sollen (Schritt 52).
public enum DraftField: String, Codable, Sendable, CaseIterable {
    /// Tagebuch-Eingabe (Lage und Bereich „Tagebuch“ teilen sich den Entwurf).
    case journal
    /// Nachricht an alle im Einsatz.
    case message
}

/// Gespeicherte Entwürfe, je Einsatz und Feld.
public struct TextDraftSet: Codable, Equatable, Sendable {
    public struct Draft: Codable, Equatable, Sendable {
        public var text: String
        public var updatedAt: Date
    }

    /// Ältere Entwürfe werden beim Laden verworfen.
    public static let maximumAge: TimeInterval = 7 * 24 * 60 * 60

    public private(set) var drafts: [String: Draft] = [:]

    public init() {}

    static func key(_ field: DraftField, mission: MissionID) -> String {
        "\(mission.rawValue.uuidString)/\(field.rawValue)"
    }

    public func text(_ field: DraftField, mission: MissionID) -> String {
        drafts[Self.key(field, mission: mission)]?.text ?? ""
    }

    /// Setzt den Entwurf; nur Leerraum entfernt ihn. `true`, wenn sich etwas geändert hat.
    @discardableResult
    public mutating func set(_ text: String, for field: DraftField, mission: MissionID, at date: Date) -> Bool {
        let key = Self.key(field, mission: mission)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return drafts.removeValue(forKey: key) != nil
        }
        guard drafts[key]?.text != text else { return false }
        drafts[key] = Draft(text: text, updatedAt: date)
        return true
    }

    /// Entfernt Entwürfe, die älter als `maximumAge` sind. `true`, wenn etwas entfernt wurde.
    @discardableResult
    public mutating func prune(now: Date) -> Bool {
        let before = drafts.count
        drafts = drafts.filter { now.timeIntervalSince($0.value.updatedAt) <= Self.maximumAge }
        return drafts.count != before
    }

    public var isEmpty: Bool { drafts.isEmpty }
}

/// Entwürfe lesen und schreiben (Gerätedokument `textDrafts`). Getippter Text
/// wird sofort im Speicher gehalten und kurz danach gesichert; `flush()` sichert
/// sofort (App geht in den Hintergrund, Ansicht verschwindet).
@MainActor
@Observable
public final class TextDraftStore {
    @ObservationIgnored private let repository: (any DocumentRepository)?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let delay: Duration
    @ObservationIgnored private var pendingWrite: Task<Void, Never>?
    @ObservationIgnored private var isDirty = false
    public private(set) var drafts: TextDraftSet
    /// Letzter Fehler beim Sichern (nur Anzeige, Text bleibt im Speicher erhalten).
    public private(set) var lastError: String?

    public init(repository: (any DocumentRepository)?, delay: Duration = .milliseconds(800), now: @escaping () -> Date = Date.init) {
        self.repository = repository
        self.now = now
        self.delay = delay
        var loaded = repository.flatMap { try? $0.document(TextDraftSet.self, key: .textDrafts) } ?? TextDraftSet()
        if loaded.prune(now: now()) {
            try? repository?.saveDocument(loaded, key: .textDrafts, at: now())
        }
        drafts = loaded
    }

    public func text(_ field: DraftField, mission: MissionID) -> String {
        drafts.text(field, mission: mission)
    }

    /// Merkt den Text und sichert ihn kurz danach (oder sofort, wenn er leer ist).
    public func update(_ text: String, for field: DraftField, mission: MissionID) {
        guard drafts.set(text, for: field, mission: mission, at: now()) else { return }
        isDirty = true
        pendingWrite?.cancel()
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            flush()
            return
        }
        let delay = delay
        pendingWrite = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Nach dem Absenden: Entwurf löschen.
    public func clear(_ field: DraftField, mission: MissionID) {
        update("", for: field, mission: mission)
    }

    /// Sichert ausstehende Änderungen sofort.
    public func flush() {
        pendingWrite?.cancel()
        pendingWrite = nil
        guard isDirty, let repository else { return }
        do {
            try repository.saveDocument(drafts, key: .textDrafts, at: now())
            isDirty = false
            lastError = nil
        } catch {
            lastError = ErrorText.message(for: error)
        }
    }
}

/// Hält ein Textfeld mit seinem gespeicherten Entwurf abgeglichen.
struct DraftSync: ViewModifier {
    @Binding var text: String
    let field: DraftField
    let mission: MissionID

    @Environment(TextDraftStore.self) private var drafts: TextDraftStore?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard text.isEmpty, let stored = drafts?.text(field, mission: mission), !stored.isEmpty else { return }
                text = stored
            }
            .onChange(of: text) { _, newText in
                drafts?.update(newText, for: field, mission: mission)
            }
            .onDisappear { drafts?.flush() }
    }
}

extension View {
    /// Ungesendeten Text als Entwurf sichern und beim nächsten Öffnen wiederherstellen.
    func draftSync(_ text: Binding<String>, field: DraftField, mission: MissionID) -> some View {
        modifier(DraftSync(text: text, field: field, mission: mission))
    }
}
