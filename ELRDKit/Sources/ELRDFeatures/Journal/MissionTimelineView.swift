import SwiftUI
import Charts
import ELRDDomain
import ELRDStore

/// Verlauf des Einsatzes (Schritt 86): Kennzahlen, Wartezeiten je SK, Verlauf der
/// Sichtungskategorien und Meilensteine – Grundlage für Bericht und Nachbesprechung.
struct MissionTimelineView: View {
    let store: MissionStore

    var body: some View {
        // Im Minutentakt neu rechnen (Laufzeit, „seit“).
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let state = store.state
            let metrics = MissionMetrics(mission: state.mission, patients: state.patients, journal: state.journal, now: context.date)
            VStack(alignment: .leading, spacing: Spacing.l) {
                if state.mission.isExerciseMission, let evaluation = ExerciseEvaluation(patients: state.patients) {
                    exerciseCard(evaluation)
                }
                tiles(metrics)
                if !metrics.waits.isEmpty { waits(metrics) }
                if metrics.patientCount > 0 { triageChart(metrics) }
                milestones(metrics)
            }
        }
    }

    // MARK: Übung (Schritt 88)

    private func exerciseCard(_ evaluation: ExerciseEvaluation) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Label("Übungsauswertung Sichtung", systemImage: "graduationcap.fill")
                .font(.headline)
                .foregroundStyle(.purple)
            Text(evaluation.summary).font(.title3.weight(.semibold))
            ForEach(evaluation.deviations, id: \.number) { deviation in
                HStack(spacing: Spacing.s) {
                    Text(deviation.number).font(.headline.monospacedDigit()).frame(minWidth: 60, alignment: .leading)
                    TriageBadgeLabel(category: deviation.actual)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    Text("erwartet").font(.subheadline).foregroundStyle(.secondary)
                    TriageBadgeLabel(category: deviation.expected)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.l)
        .background(Color.purple.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: Kennzahlen

    private func tiles(_ metrics: MissionMetrics) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Spacing.m)], spacing: Spacing.m) {
            tile("Laufzeit", ElapsedTimeFormat.string(from: metrics.start, to: metrics.end ?? metrics.now),
                 caption: "seit \(metrics.start.formatted(date: .omitted, time: .shortened))")
            tile("Patienten", "\(metrics.patientCount)", caption: nil)
            milestoneTile("Erste Sichtung", metrics.firstTriageAt, metrics)
            milestoneTile("Alle gesichtet", metrics.allTriagedAt, metrics)
            milestoneTile("Erster Transport", metrics.firstTransportAt, metrics)
            milestoneTile("Letzter versorgt", metrics.lastPatientGoneAt, metrics)
        }
    }

    private func milestoneTile(_ title: String, _ date: Date?, _ metrics: MissionMetrics) -> some View {
        tile(
            title,
            metrics.minutesFromStart(date).map { "+\($0) min" } ?? "–",
            caption: date.map { "\($0.formatted(date: .omitted, time: .shortened)) Uhr" } ?? "noch nicht"
        )
    }

    private func tile(_ title: String, _ value: String, caption: String?) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.heavy).monospacedDigit())
            if let caption {
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.m)
        .background(Surface.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    // MARK: Wartezeiten

    private func waits(_ metrics: MissionMetrics) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Wartezeit bis Transportbeginn").font(.headline)
            ForEach([Sichtungskategorie.sk1, .sk2, .sk3], id: \.self) { category in
                if let wait = metrics.waits[category] {
                    HStack(spacing: Spacing.m) {
                        TriageBadgeLabel(category: category)
                        Text("Ø \(wait.averageMinutes) min · längste \(wait.maximumMinutes) min")
                            .font(.body.monospacedDigit())
                        Spacer()
                        Text(wait.count == 1 ? "1 Patient" : "\(wait.count) Patienten")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // MARK: SK-Verlauf

    private struct ChartPoint: Identifiable {
        let id: String
        let date: Date
        let triage: Sichtungskategorie
        let count: Int
    }

    private static let chartOrder: [Sichtungskategorie] = [.sk1, .sk2, .sk3, .ungesichtet, .unverletzt, .verstorben]

    private func chartPoints(_ metrics: MissionMetrics) -> [ChartPoint] {
        var series = metrics.triageSeries
        // Bis jetzt bzw. Einsatzende fortführen.
        if let last = series.last {
            series.append(MissionMetrics.TriagePoint(date: max(last.date, metrics.end ?? metrics.now), counts: last.counts))
        }
        let used = MissionTimelineView.chartOrder.filter { triage in series.contains { $0.count(triage) > 0 } }
        return series.enumerated().flatMap { index, point in
            used.map { triage in
                ChartPoint(id: "\(index)-\(triage.rawValue)", date: point.date, triage: triage, count: point.count(triage))
            }
        }
    }

    private func triageChart(_ metrics: MissionMetrics) -> some View {
        let points = chartPoints(metrics)
        let used = MissionTimelineView.chartOrder.filter { triage in points.contains { $0.triage == triage } }
        return VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Sichtungskategorien im Verlauf").font(.headline)
            Chart(points) { point in
                LineMark(
                    x: .value("Zeit", point.date),
                    y: .value("Patienten", point.count)
                )
                .foregroundStyle(by: .value("Kategorie", point.triage.shortName))
                .interpolationMethod(.stepEnd)
                .lineStyle(StrokeStyle(lineWidth: 3))
            }
            .chartForegroundStyleScale(domain: used.map(\.shortName), range: used.map { Color.triage($0) })
            .chartYAxis { AxisMarks(position: .leading) }
            .frame(height: 220)
            .accessibilityLabel("Verlauf der Sichtungskategorien")
        }
        .cardStyle()
    }

    // MARK: Meilensteine

    private func milestones(_ metrics: MissionMetrics) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Meilensteine").font(.headline).padding(.bottom, Spacing.s)
            ForEach(Array(metrics.milestones.enumerated()), id: \.element.id) { index, milestone in
                HStack(alignment: .top, spacing: Spacing.m) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(milestone.date.formatted(date: .omitted, time: .shortened))
                            .font(.headline.monospacedDigit())
                        if let offset = metrics.minutesFromStart(milestone.date), milestone.kind != .start {
                            Text("+\(offset) min").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 70, alignment: .trailing)
                    VStack(spacing: 0) {
                        Circle()
                            .fill(color(for: milestone.kind))
                            .frame(width: 14, height: 14)
                            .padding(.top, 4)
                        if index < metrics.milestones.count - 1 {
                            Rectangle().fill(Surface.separator).frame(width: 2).frame(maxHeight: .infinity)
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(milestone.title).font(.headline)
                        if let detail = milestone.detail, !detail.isEmpty {
                            Text(detail).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.bottom, Spacing.l)
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func color(for kind: MissionMetrics.MilestoneKind) -> Color {
        switch kind {
        case .start, .end: .primary
        case .firstPatient, .firstTriage, .allTriaged: Color.triage(.sk2)
        case .firstTransport, .lastPatientGone: Color.triage(.sk3)
        case .situationReport, .handover: .blue
        case .request: .orange
        }
    }
}

/// Kleines SK-Abzeichen für Zeilen.
private struct TriageBadgeLabel: View {
    let category: Sichtungskategorie

    var body: some View {
        Text(category.shortName)
            .font(.subheadline.weight(.bold))
            .foregroundStyle(Color(category.color.contrastingTextColor))
            .frame(width: 52, height: 30)
            .background(Color.triage(category), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
