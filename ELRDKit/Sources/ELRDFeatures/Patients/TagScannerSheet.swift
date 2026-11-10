import SwiftUI
import UIKit
import VisionKit
import ELRDDomain
import ELRDStore

/// Patientenanhängekarte scannen (Schritt 72): Barcode per Kamera, sonst Nummer
/// eintippen. Bekannte Karte → Patient öffnen; neue Karte → Patient mit SK anlegen.
struct TagScannerSheet: View {
    let store: MissionStore
    let onOpen: (PatientID) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""
    @State private var scanned: String?
    @State private var errorMessage: String?
    /// Schritt 110: NFC-Karten (nur iPhone).
    @State private var nfc = NFCCardReader()

    private var scannerAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    if let scanned {
                        result(for: scanned)
                    } else {
                        if scannerAvailable {
                            BarcodeScannerView { code in
                                UINotificationFeedbackGenerator().notificationOccurred(.success)
                                scanned = Patient.normalizedTag(code)
                            }
                            .frame(height: 320)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .accessibilityLabel("Kamera: Barcode der Anhängekarte ins Bild halten")
                        } else {
                            Label("Kamera zum Scannen hier nicht verfügbar – Nummer eintippen.", systemImage: "barcode.viewfinder")
                                .foregroundStyle(.secondary)
                        }
                        if NFCCardReader.isAvailable {
                            Button(action: readNFC) {
                                Label("NFC-Karte ans iPhone halten", systemImage: "wave.3.right.circle.fill")
                                    .font(.title3.weight(.semibold))
                                    .frame(maxWidth: .infinity, minHeight: TouchTarget.large)
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityHint("Liest die Nummer vom Chip der Anhängekarte – auch im Dunkeln")
                        }
                        HStack(spacing: Spacing.s) {
                            TextField("Kartennummer", text: $typed)
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                                .font(.title3.monospaced())
                                .inputBox()
                                .onSubmit(useTyped)
                            Button("Suchen", action: useTyped)
                                .font(.headline)
                                .buttonStyle(.borderedProminent)
                                .frame(minHeight: TouchTarget.comfortable)
                                .disabled(Patient.normalizedTag(typed) == nil)
                        }
                    }
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                .padding(Spacing.xl)
            }
            .background(Surface.canvas)
            .navigationTitle("Anhängekarte")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Schließen") { dismiss() } }
            }
        }
    }

    private func readNFC() {
        errorMessage = nil
        nfc.read { result in
            switch result {
            case .success(let text):
                guard let tag = Patient.normalizedTag(text) else {
                    errorMessage = "Auf der Karte steht keine gültige Nummer."
                    return
                }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                scanned = tag
            case .failure(let error):
                errorMessage = error.errorDescription
            }
        }
    }

    private func useTyped() {
        scanned = Patient.normalizedTag(typed)
    }

    @ViewBuilder
    private func result(for tag: String) -> some View {
        Text("Karte \(tag)")
            .font(.title2.weight(.bold).monospaced())
        if let patient = store.state.patient(withTag: tag) {
            Button {
                dismiss()
                onOpen(patient.id)
            } label: {
                HStack(spacing: Spacing.m) {
                    Text(patient.triage.shortName)
                        .font(.headline.weight(.heavy))
                        .foregroundStyle(Color.onTriage(patient.triage))
                        .frame(minWidth: 56, minHeight: 40)
                        .background(Color.triage(patient.triage), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading) {
                        Text(patient.displayName).font(.headline)
                        Text(patient.status.displayName).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                .padding(Spacing.l)
                .frame(minHeight: TouchTarget.large)
                .background(Surface.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
        } else if store.state.mission.isClosed {
            Text("Kein Patient mit dieser Karte. Der Einsatz ist beendet.")
                .foregroundStyle(.secondary)
        } else {
            Text("Neue Karte – Patient anlegen:")
                .font(.headline)
            HStack(spacing: Spacing.s) {
                ForEach([Sichtungskategorie.sk1, .sk2, .sk3, .unverletzt, .ungesichtet], id: \.self) { triage in
                    Button { create(triage, tag: tag) } label: {
                        Text(triage.shortName)
                            .font(.title3.weight(.heavy))
                            .foregroundStyle(Color.onTriage(triage))
                            .frame(maxWidth: .infinity, minHeight: TouchTarget.large)
                            .background(Color.triage(triage), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Patient \(triage.displayName) anlegen")
                }
            }
        }
        Button("Andere Karte scannen") {
            scanned = nil
            typed = ""
            errorMessage = nil
        }
        .frame(minHeight: TouchTarget.comfortable)
    }

    private func create(_ triage: Sichtungskategorie, tag: String) {
        do {
            let patient = try store.perform(AddPatient(triage: triage, tagNumber: tag))
            dismiss()
            onOpen(patient.id)
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }
}

/// Kamera mit Barcode-Erkennung (VisionKit). Meldet den ersten erkannten Code.
struct BarcodeScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode()],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        try? controller.startScanning()
        return controller
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
        if !controller.isScanning { try? controller.startScanning() }
    }

    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        controller.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        private var reported = false

        init(onCode: @escaping (String) -> Void) {
            self.onCode = onCode
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !reported else { return }
            for item in addedItems {
                if case .barcode(let barcode) = item, let value = barcode.payloadStringValue, !value.isEmpty {
                    reported = true
                    onCode(value)
                    return
                }
            }
        }
    }
}
