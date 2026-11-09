import SwiftUI
import UIKit

/// Text groß anzeigen zum Vorlesen, teilen, kopieren oder mailen
/// (ATMIST-Übergabe, Schritt 97; Klinik-Voranmeldung, Schritt 98).
struct ShareTextSheet: View {
    let title: String
    let text: String
    /// Empfänger für „Per Mail“ (optional).
    var email: String? = nil
    var subject: String = ""
    var footnote: String? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    Text(text)
                        .font(.title3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Spacing.l)
                        .background(Surface.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: Spacing.m) { buttons }
                        VStack(alignment: .leading, spacing: Spacing.m) { buttons }
                    }
                    if let footnote {
                        Text(footnote).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(Spacing.xl)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .background(Surface.canvas)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() }.fontWeight(.bold) }
            }
        }
    }

    @ViewBuilder private var buttons: some View {
        ShareLink(item: text, subject: Text(subject)) {
            Label("Teilen", systemImage: "square.and.arrow.up")
                .font(.headline)
                .frame(minHeight: TouchTarget.comfortable)
                .padding(.horizontal, Spacing.l)
        }
        .buttonStyle(.borderedProminent)
        Button {
            UIPasteboard.general.string = text
            copied = true
        } label: {
            Label(copied ? "Kopiert" : "Kopieren", systemImage: copied ? "checkmark" : "doc.on.doc")
                .font(.headline)
                .frame(minHeight: TouchTarget.comfortable)
                .padding(.horizontal, Spacing.l)
        }
        .buttonStyle(.bordered)
        if let url = mailURL {
            Button { openURL(url) } label: {
                Label("Per Mail", systemImage: "envelope")
                    .font(.headline)
                    .frame(minHeight: TouchTarget.comfortable)
                    .padding(.horizontal, Spacing.l)
            }
            .buttonStyle(.bordered)
        }
    }

    private var mailURL: URL? {
        guard let email, !email.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = email
        components.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: text)]
        return components.url
    }
}
