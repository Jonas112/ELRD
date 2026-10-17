import ELRDDomain

/// ELRDAuth – Benutzer und Anmeldung.
///
/// Lokale Benutzer mit Passwort (PBKDF2-Hash, nie Klartext), Keychain-Zugriff und
/// das `AuthProvider`-Protokoll, damit später ein Backend-Konto verknüpft werden kann.
public enum ELRDAuthModule {
    public static let name = "ELRDAuth"
}
