import ELRDDomain

/// ELRDSync – Grundlage für den Mehrbenutzer-Modus.
///
/// Änderungsjournal (append-only), Hybrid-Logical-Clock und das Protokoll für
/// spätere Transporte (ELRD-Backend, lokales Netzwerk). Zunächst nur lokal aktiv.
public enum ELRDSyncModule {
    public static let name = "ELRDSync"
}
