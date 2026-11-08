import ActivityKit
import SwiftUI
import WidgetKit

/// Live Activity eines laufenden Einsatzes (Schritt 90): Laufzeit, SK-Zähler und
/// nächste Lagemeldung auf Sperrbildschirm und Dynamic Island – ohne Patientennamen
/// (E105). Aktualisiert nur lokal von der App, kein Push-Server.
public struct MissionActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public var sk1: Int
        public var sk2: Int
        public var sk3: Int
        public var untriaged: Int
        public var waiting: Int
        public var openItems: Int
        /// Nächste fällige Lagemeldung (`nil` = Erinnerung aus).
        public var nextReportAt: Date?

        public init(sk1: Int, sk2: Int, sk3: Int, untriaged: Int, waiting: Int, openItems: Int, nextReportAt: Date?) {
            self.sk1 = sk1
            self.sk2 = sk2
            self.sk3 = sk3
            self.untriaged = untriaged
            self.waiting = waiting
            self.openItems = openItems
            self.nextReportAt = nextReportAt
        }
    }

    public var missionID: String
    /// „2026/6“
    public var missionNumber: String
    /// Einsatzstichwort/Meldebild (keine Patientendaten).
    public var title: String
    public var startedAt: Date
    public var isExercise: Bool

    public init(missionID: String, missionNumber: String, title: String, startedAt: Date, isExercise: Bool) {
        self.missionID = missionID
        self.missionNumber = missionNumber
        self.title = title
        self.startedAt = startedAt
        self.isExercise = isExercise
    }
}

/// Darstellung im Widget-Ziel (`ELRDWidgets`).
public struct MissionLiveActivityWidget: Widget {
    public init() {}

    public var body: some WidgetConfiguration {
        ActivityConfiguration(for: MissionActivityAttributes.self) { context in
            MissionLockScreenView(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.75))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.isExercise ? "ÜBUNG" : "Einsatz").font(.caption2.weight(.bold))
                        Text(context.attributes.startedAt, style: .timer).font(.title3.monospacedDigit().weight(.bold))
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.openItems > 0 {
                        Label("\(context.state.openItems)", systemImage: "exclamationmark.circle.fill")
                            .font(.headline).foregroundStyle(.orange)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        TriageCountsRow(state: context.state)
                        if let next = context.state.nextReportAt {
                            ReportDueText(date: next).font(.caption)
                        }
                    }
                }
            } compactLeading: {
                Text("\(context.state.sk1)").font(.headline.weight(.heavy)).foregroundStyle(MissionActivityColors.sk1)
            } compactTrailing: {
                Text(context.attributes.startedAt, style: .timer)
                    .monospacedDigit()
                    .frame(maxWidth: 52)
            } minimal: {
                Text("\(context.state.sk1)").font(.caption.weight(.heavy)).foregroundStyle(MissionActivityColors.sk1)
            }
        }
    }
}

enum MissionActivityColors {
    static let sk1 = Color(red: 0.84, green: 0.16, blue: 0.16)
    static let sk2 = Color(red: 1.0, green: 0.76, blue: 0.0)
    static let sk3 = Color(red: 0.16, green: 0.55, blue: 0.24)
    static let untriaged = Color(white: 0.6)
}

struct MissionLockScreenView: View {
    let attributes: MissionActivityAttributes
    let state: MissionActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(attributes.isExercise ? "ÜBUNG \(attributes.missionNumber)" : "Einsatz \(attributes.missionNumber)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(attributes.isExercise ? .purple : .white.opacity(0.7))
                    Text(attributes.title).font(.headline).foregroundStyle(.white).lineLimit(1)
                }
                Spacer()
                Text(attributes.startedAt, style: .timer)
                    .font(.title2.monospacedDigit().weight(.bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 110, alignment: .trailing)
            }
            TriageCountsRow(state: state)
            HStack {
                if let next = state.nextReportAt {
                    ReportDueText(date: next)
                }
                Spacer()
                if state.openItems > 0 {
                    Label(state.openItems == 1 ? "1 offener Punkt" : "\(state.openItems) offene Punkte", systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.85))
        }
        .padding(14)
    }
}

struct TriageCountsRow: View {
    let state: MissionActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 6) {
            badge("SK 1", state.sk1, MissionActivityColors.sk1, .white)
            badge("SK 2", state.sk2, MissionActivityColors.sk2, .black)
            badge("SK 3", state.sk3, MissionActivityColors.sk3, .white)
            badge("?", state.untriaged, MissionActivityColors.untriaged, .black)
            VStack(spacing: 0) {
                Text("\(state.waiting)").font(.headline.weight(.heavy))
                Text("warten").font(.caption2)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
        }
    }

    private func badge(_ title: String, _ count: Int, _ fill: Color, _ text: Color) -> some View {
        VStack(spacing: 0) {
            Text(title).font(.caption2.weight(.bold))
            Text("\(count)").font(.headline.weight(.heavy))
        }
        .foregroundStyle(text)
        .frame(maxWidth: .infinity, minHeight: 40)
        .background(fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct ReportDueText: View {
    let date: Date

    var body: some View {
        if date > Date() {
            HStack(spacing: 4) {
                Image(systemName: "megaphone.fill")
                Text("Lagemeldung in")
                Text(date, style: .relative)
            }
        } else {
            Label("Lagemeldung fällig", systemImage: "megaphone.fill").foregroundStyle(.orange)
        }
    }
}
