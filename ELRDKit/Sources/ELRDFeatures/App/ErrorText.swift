import Foundation

/// Verständliche deutsche Fehlertexte für die Oberfläche (Schritt 52).
///
/// Eigene Fehler bringen ihren Text mit (`LocalizedError`). Systemfehler wie
/// „Speicher voll“ oder „Gerät gesperrt“ bekommen einen eigenen Hinweis; alles
/// andere einen allgemeinen Text mit Fehlercode für die Rückfrage beim Support.
/// Personenbezogene Daten stehen nie im Text.
public enum ErrorText {
    public static func message(for error: any Error) -> String {
        let nsError = error as NSError
        if let known = systemMessage(domain: nsError.domain, code: nsError.code) {
            return known
        }
        let text = (error as? any LocalizedError)?.errorDescription ?? nsError.localizedDescription
        if !text.isEmpty, !isSwiftDefault(text) {
            return text
        }
        return "Unerwarteter Fehler – die letzte Änderung wurde nicht gespeichert. Bitte erneut versuchen. (\(shortCode(nsError)))"
    }

    /// Hinweise für bekannte Systemfehler.
    static func systemMessage(domain: String, code: Int) -> String? {
        switch (domain, code) {
        case (NSCocoaErrorDomain, NSFileWriteOutOfSpaceError), (NSPOSIXErrorDomain, Int(ENOSPC)):
            "Der Speicher des iPads ist voll. Bitte Platz schaffen (z. B. Fotos oder Apps löschen) und erneut versuchen."
        case (NSCocoaErrorDomain, NSFileWriteNoPermissionError), (NSCocoaErrorDomain, NSFileReadNoPermissionError),
             (NSPOSIXErrorDomain, Int(EPERM)), (NSPOSIXErrorDomain, Int(EACCES)):
            "Kein Zugriff auf die Daten – ist das iPad gesperrt? Bitte entsperren und erneut versuchen."
        case (NSCocoaErrorDomain, NSFileReadCorruptFileError), (NSCocoaErrorDomain, NSCoderReadCorruptError):
            "Gespeicherte Daten sind beschädigt und ließen sich nicht lesen."
        case (NSURLErrorDomain, NSURLErrorNotConnectedToInternet), (NSURLErrorDomain, NSURLErrorNetworkConnectionLost):
            "Keine Internetverbindung."
        default:
            nil
        }
    }

    /// Swift erzeugt für Fehler ohne eigenen Text „The operation couldn’t be completed …“.
    private static func isSwiftDefault(_ text: String) -> Bool {
        text.contains("The operation couldn") || text.contains("Der Vorgang konnte nicht abgeschlossen werden")
    }

    static func shortCode(_ error: NSError) -> String {
        let domain = error.domain.split(separator: ".").last.map(String.init) ?? error.domain
        return "\(domain) \(error.code)"
    }
}
