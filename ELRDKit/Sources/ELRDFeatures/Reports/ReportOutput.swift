import SwiftUI
import UIKit
import PDFKit
import MessageUI
import ELRDDomain
import ELRDReports
import ELRDStore
import ELRDPersistence

/// Eingabe für den Bericht aus dem aktuellen Einsatzstand.
enum ReportInputFactory {
    @MainActor
    static func make(store: MissionStore, people: [PersonChoice], attachments: AttachmentFileStore, now: Date = Date()) -> ReportInput {
        let state = store.state
        let files = attachments
        return ReportInput(
            mission: state.mission,
            patients: state.patients,
            units: state.units,
            sections: state.sections,
            journal: state.journal,
            log: state.visibleLog,
            people: Dictionary(people.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }),
            createdAt: now,
            createdBy: store.sessionDisplayName,
            imageData: { file in files.data(for: file) }
        )
    }
}

/// Dateiname wie „Einsatzbericht 2026-12 VU B 19 2026-11-07.pdf“ – ohne Zeichen,
/// die Dateisysteme oder Mailprogramme stören (Schritt 46).
enum ReportFileName {
    static func make(template: String, mission: Mission, date: Date) -> String {
        let day = date.formatted(.iso8601.year().month().day())
        let raw = "\(template) \(mission.displayNumber().replacingOccurrences(of: "/", with: "-")) \(mission.title) \(day)"
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        let cleaned = raw.components(separatedBy: forbidden).joined(separator: " ")
        let collapsed = cleaned.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return String(collapsed.prefix(120)) + ".pdf"
    }

    /// Legt die Datei im temporären Ordner ab (zum Teilen).
    static func write(_ data: Data, named name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Berichte", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return url
    }
}

/// PDF-Vorschau (PDFKit).
struct PDFPreview: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .secondarySystemBackground
        view.document = PDFDocument(data: data)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        guard view.document?.dataRepresentation() != data else { return }
        view.document = PDFDocument(data: data)
        view.autoScales = true
    }
}

/// Drucken (AirPrint).
@MainActor
enum ReportPrinting {
    static func print(_ data: Data, jobName: String) {
        let info = UIPrintInfo(dictionary: nil)
        info.jobName = jobName
        info.outputType = .general
        let controller = UIPrintInteractionController.shared
        controller.printInfo = info
        controller.printingItem = data
        controller.present(animated: true)
    }
}

/// Mail an die Leitstelle mit dem PDF als Anhang.
struct MailComposer: UIViewControllerRepresentable {
    let recipient: String
    let subject: String
    let body: String
    let attachment: Data
    let fileName: String
    let onFinish: () -> Void

    static var canSend: Bool { MFMailComposeViewController.canSendMail() }

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.mailComposeDelegate = context.coordinator
        if !recipient.isEmpty { controller.setToRecipients([recipient]) }
        controller.setSubject(subject)
        controller.setMessageBody(body, isHTML: false)
        controller.addAttachmentData(attachment, mimeType: "application/pdf", fileName: fileName)
        return controller
    }

    func updateUIViewController(_ controller: MFMailComposeViewController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onFinish: () -> Void

        init(onFinish: @escaping () -> Void) {
            self.onFinish = onFinish
        }

        func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: (any Error)?) {
            onFinish()
        }
    }
}
