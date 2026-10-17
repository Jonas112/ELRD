import SwiftUI
import ELRDDomain
import ELRDPersistence
import ELRDSync
import ELRDAuth
import ELRDEntitlements
import ELRDReports
import ELRDStammdaten

/// Einstiegsansicht der App.
///
/// Platzhalter für Schritt 2: zeigt, dass alle Module gebaut und gelinkt werden.
/// Der eigentliche App-Rahmen mit adaptiver Navigation folgt in Schritt 14.
public struct RootView: View {
    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                Section("Module") {
                    ForEach(Self.moduleNames, id: \.self) { name in
                        Label(name, systemImage: "shippingbox")
                    }
                }
            }
            .navigationTitle("ELRD")
        }
    }

    static let moduleNames: [String] = [
        ELRDDomainModule.name,
        ELRDPersistenceModule.name,
        ELRDSyncModule.name,
        ELRDAuthModule.name,
        ELRDEntitlementsModule.name,
        ELRDReportsModule.name,
        ELRDStammdatenModule.name,
    ]
}

#Preview {
    RootView()
}
