import Foundation
import ELRDDomain

/// Einheitliche Zahlen- und Datumsformate im Bericht (deutsch, unabhängig vom Gerät).
enum ReportFormat {
    static let locale = Locale(identifier: "de_DE")

    static func dateTime(_ date: Date) -> String {
        date.formatted(.dateTime.locale(locale).day(.twoDigits).month(.twoDigits).year().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }

    static func time(_ date: Date) -> String {
        date.formatted(.dateTime.locale(locale).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }

    /// „2:05 h“ bzw. „1 T 2:05 h“.
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(seconds, 0) / 60)
        let days = minutes / (24 * 60)
        let hours = (minutes / 60) % 24
        let rest = minutes % 60
        let clock = String(format: "%d:%02d h", hours, rest)
        return days > 0 ? "\(days) T \(clock)" : clock
    }

    /// „N 50,10000° · O 10,18000°“ (Süd/West mit S/W).
    static func coordinate(_ coordinate: GeoCoordinate) -> String {
        func degrees(_ value: Double) -> String {
            String(format: "%.5f", abs(value)).replacingOccurrences(of: ".", with: ",") + "°"
        }
        let north = coordinate.latitude >= 0 ? "N" : "S"
        let east = coordinate.longitude >= 0 ? "O" : "W"
        return "\(north) \(degrees(coordinate.latitude)) · \(east) \(degrees(coordinate.longitude))"
    }

    /// „A-1 (SK 1)“.
    static func patientLabel(_ patient: Patient) -> String {
        "\(patient.number) (\(patient.triage.shortName))"
    }
}
