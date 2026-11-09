import SwiftUI
import ELRDDomain
import ELRDStore

/// Telefonbuch im Einsatz (Schritt 99): eigene Nummern (ILS, Polizei …), die im
/// Einsatz eingetragene Führung, Führungspersonal aus den Einstellungen und
/// Kliniken aus den Stammdaten – Tipp ruft an.
struct PhoneBookSheet: View {
    let store: MissionStore
    let settings: AppSettings
    let hospitals: [MasterHospital]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var query = ""

    private struct Entry: Identifiable {
        let id: String
        let name: String
        let detail: String
        let number: String
    }

    var body: some View {
        let custom = settings.phoneBook
            .filter { !$0.number.isEmpty }
            .map { Entry(id: "c-\($0.id)", name: $0.name.isEmpty ? $0.number : $0.name, detail: "", number: $0.number) }
        let leadership = settings.leadershipPeople
            .filter { ($0.phone ?? "").isEmpty == false }
            .map { person in
                Entry(id: "l-\(person.id)", name: person.name,
                      detail: [person.roles.map(\.shortName).joined(separator: ", "), person.callsign].filter { !$0.isEmpty }.joined(separator: " · "),
                      number: person.phone ?? "")
            }
        // Zielkliniken dieses Einsatzes zuerst.
        let targets = Set(store.state.patients.active.compactMap { $0.destination.map { HospitalQuota.key($0.name) } })
        let clinics = hospitals
            .filter { !$0.phone.isEmpty }
            .sorted { (targets.contains(HospitalQuota.key($0.name)) ? 0 : 1, $0.name) < (targets.contains(HospitalQuota.key($1.name)) ? 0 : 1, $1.name) }
            .map { Entry(id: "h-\($0.id.rawValue)", name: $0.name, detail: [$0.city, targets.contains(HospitalQuota.key($0.name)) ? "Ziel in diesem Einsatz" : ""].filter { !$0.isEmpty }.joined(separator: " · "), number: $0.phone) }

        NavigationStack {
            List {
                section("Eigene Nummern", filter(custom), empty: "In den Einstellungen unter „Führungspersonal › Telefonbuch“ eintragen.")
                section("Führungspersonal", filter(leadership), empty: "Bei Personen im Führungspersonal eine Telefonnummer eintragen.")
                section("Kliniken", filter(clinics), empty: "Keine Klinik mit Telefonnummer in den Stammdaten.")
            }
            .searchable(text: $query, prompt: "Name suchen")
            .navigationTitle("Telefonbuch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() }.fontWeight(.bold) }
            }
        }
    }

    private func filter(_ entries: [Entry]) -> [Entry] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return entries }
        return entries.filter { $0.name.localizedCaseInsensitiveContains(text) || $0.detail.localizedCaseInsensitiveContains(text) }
    }

    @ViewBuilder
    private func section(_ title: String, _ entries: [Entry], empty: String) -> some View {
        Section(title) {
            if entries.isEmpty {
                Text(query.isEmpty ? empty : "Kein Treffer.").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(entries) { entry in
                Button {
                    if let url = PhoneEntry.telURL(entry.number) { openURL(url) }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name).font(.headline).foregroundStyle(.primary)
                            if !entry.detail.isEmpty {
                                Text(entry.detail).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Label(entry.number, systemImage: "phone.fill")
                            .font(.headline.monospacedDigit())
                    }
                    .frame(minHeight: TouchTarget.comfortable)
                }
                .disabled(PhoneEntry.telURL(entry.number) == nil)
            }
        }
    }
}
