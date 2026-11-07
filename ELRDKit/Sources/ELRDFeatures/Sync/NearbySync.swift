import Foundation
import MultipeerConnectivity
import Observation
import SwiftUI
import ELRDDomain
import ELRDStore
import ELRDPersistence

// MARK: - Abgleich vor Ort ohne Server (Schritt 66)

/// Abgleich zwischen iPads in der Nähe über Apples MultipeerConnectivity (WLAN,
/// Peer-to-Peer-WLAN oder Bluetooth – ohne Internet und ohne Server). Verbunden
/// wird nur nach Bestätigung auf beiden Geräten; die Verbindung ist verschlüsselt.
@MainActor
@Observable
final class NearbySyncSession: NSObject {
    static let serviceType = "elrd-sync"

    struct Peer: Identifiable, Equatable {
        let peerID: MCPeerID
        let missionID: MissionID
        let missionTitle: String
        var id: String { "\(peerID.displayName)|\(missionID.rawValue.uuidString)" }
        var name: String { peerID.displayName }
    }

    enum Phase: Equatable {
        case searching
        case connecting(String)
        case exchanging(String)
        case done(String)
        case failed(String)
    }

    private(set) var peers: [Peer] = []
    private(set) var phase: Phase = .searching
    /// Anfrage eines anderen Geräts, wartet auf „Annehmen“.
    private(set) var invitation: (name: String, missionTitle: String)?
    private(set) var progress = NearbyExchange.Progress()
    /// Einsatz, der abgeglichen wird (`nil` beim Übernehmen, bis ein Gerät gewählt ist).
    private(set) var missionID: MissionID?

    @ObservationIgnored private let myPeer: MCPeerID
    @ObservationIgnored private let session: MCSession
    @ObservationIgnored private var advertiser: MCNearbyServiceAdvertiser?
    @ObservationIgnored private let browser: MCNearbyServiceBrowser
    @ObservationIgnored private var pendingInvitation: ((Bool, MCSession?) -> Void)?
    @ObservationIgnored private var exchange: NearbyExchange?
    @ObservationIgnored private let makeExchange: (MissionID) -> NearbyExchange
    @ObservationIgnored private let missionTitle: String
    /// Nach jeder Übernahme (offenen Einsatz neu laden).
    @ObservationIgnored var onImported: () -> Void = {}

    /// - Parameter missionID: eigener Einsatz (wird angeboten); `nil` = nur suchen
    ///   und einen Einsatz von einem anderen iPad übernehmen.
    init(
        displayName: String,
        missionID: MissionID?,
        missionTitle: String,
        makeExchange: @escaping (MissionID) -> NearbyExchange
    ) {
        let name = String(displayName.prefix(60)).trimmingCharacters(in: .whitespaces)
        myPeer = MCPeerID(displayName: name.isEmpty ? "ELRD" : name)
        session = MCSession(peer: myPeer, securityIdentity: nil, encryptionPreference: .required)
        browser = MCNearbyServiceBrowser(peer: myPeer, serviceType: Self.serviceType)
        self.missionID = missionID
        self.missionTitle = missionTitle
        self.makeExchange = makeExchange
        super.init()
        session.delegate = self
        browser.delegate = self
        if let missionID {
            let info = ["mission": missionID.rawValue.uuidString, "title": String(missionTitle.prefix(80))]
            let advertiser = MCNearbyServiceAdvertiser(peer: myPeer, discoveryInfo: info, serviceType: Self.serviceType)
            advertiser.delegate = self
            self.advertiser = advertiser
            exchange = makeExchange(missionID)
        }
    }

    func start() {
        advertiser?.startAdvertisingPeer()
        browser.startBrowsingForPeers()
    }

    func stop() {
        advertiser?.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        session.disconnect()
        pendingInvitation?(false, nil)
        pendingInvitation = nil
    }

    /// Geräte, mit denen abgeglichen werden kann: gleicher Einsatz – oder beim
    /// Übernehmen jedes Gerät, das einen Einsatz anbietet.
    var matchingPeers: [Peer] {
        guard let missionID, advertiser != nil else { return peers }
        return peers.filter { $0.missionID == missionID }
    }

    func connect(_ peer: Peer) {
        if missionID == nil {
            missionID = peer.missionID
            exchange = makeExchange(peer.missionID)
        }
        phase = .connecting(peer.name)
        browser.invitePeer(peer.peerID, to: session, withContext: nil, timeout: 30)
    }

    func answerInvitation(_ accept: Bool) {
        pendingInvitation?(accept, accept ? session : nil)
        pendingInvitation = nil
        if let invitation, accept { phase = .connecting(invitation.name) }
        invitation = nil
    }

    /// Eigenen Stand nochmal schicken (z. B. nach weiteren Änderungen).
    func syncAgain() {
        sendSnapshot(to: session.connectedPeers)
    }

    // MARK: Ablauf

    private func sendSnapshot(to peers: [MCPeerID]) {
        guard !peers.isEmpty, let exchange else { return }
        do {
            if let message = try exchange.snapshot() {
                try session.send(message.encoded(), toPeers: peers, with: .reliable)
            }
            phase = .exchanging(peers.map(\.displayName).joined(separator: ", "))
        } catch {
            phase = .failed(ErrorText.message(for: error))
        }
    }

    private func receive(_ data: Data, from peer: MCPeerID) {
        guard let exchange else { return }
        do {
            let message = try NearbyMessage.decode(data)
            let replies = try exchange.handle(message)
            for reply in replies {
                try session.send(reply.encoded(), toPeers: [peer], with: .reliable)
            }
            progress = exchange.progress
            if case .events = message { onImported() }
            if case .file = message { onImported() }
            phase = .done(peer.displayName)
        } catch {
            phase = .failed(ErrorText.message(for: error))
        }
    }

    private func found(_ peer: MCPeerID, info: [String: String]?) {
        guard let raw = info?["mission"], let uuid = UUID(uuidString: raw) else { return }
        let entry = Peer(peerID: peer, missionID: MissionID(uuid), missionTitle: info?["title"] ?? "Einsatz")
        peers.removeAll { $0.peerID == peer }
        peers.append(entry)
    }

    private func lost(_ peer: MCPeerID) {
        peers.removeAll { $0.peerID == peer }
    }

    private func changed(_ peer: MCPeerID, to state: MCSessionState) {
        switch state {
        case .connected:
            sendSnapshot(to: [peer])
        case .notConnected:
            if case .connecting = phase { phase = .failed("Verbindung zu \(peer.displayName) nicht zustande gekommen.") }
        case .connecting:
            phase = .connecting(peer.displayName)
        @unknown default:
            break
        }
    }

    private func invited(by peer: MCPeerID, handler: @escaping (Bool, MCSession?) -> Void) {
        pendingInvitation?(false, nil)
        pendingInvitation = handler
        invitation = (peer.displayName, missionTitle)
    }
}

// MARK: Delegates (Rückrufe kommen auf beliebigen Threads)

extension NearbySyncSession: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in self.changed(peerID, to: state) }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor in self.receive(data, from: peerID) }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: (any Error)?) {}
}

extension NearbySyncSession: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in self.found(peerID, info: info) }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in self.lost(peerID) }
    }
}

extension NearbySyncSession: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                                withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        Task { @MainActor in self.invited(by: peerID, handler: invitationHandler) }
    }
}

// MARK: - Oberfläche

/// „Mit iPad in der Nähe abgleichen“ (Einsatzdaten) bzw. „Einsatz von iPad in
/// der Nähe übernehmen“ (Einsatzliste).
struct NearbySyncView: View {
    @State var session: NearbySyncSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    statusRow
                } footer: {
                    Text("Funktioniert ohne Internet über WLAN oder Bluetooth. Beide iPads müssen diesen Bildschirm geöffnet haben; verbunden wird erst nach „Annehmen“ auf dem anderen Gerät.")
                }
                Section(session.missionID == nil ? "Einsätze in der Nähe" : "iPads mit diesem Einsatz") {
                    if session.matchingPeers.isEmpty {
                        Label("Suche …", systemImage: "antenna.radiowaves.left.and.right")
                            .foregroundStyle(.secondary)
                            .frame(minHeight: TouchTarget.minimum)
                    }
                    ForEach(session.matchingPeers) { peer in
                        Button { session.connect(peer) } label: {
                            HStack {
                                Image(systemName: "ipad.landscape").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(peer.name).font(.headline).foregroundStyle(.primary)
                                    Text(peer.missionTitle).font(.subheadline).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("Verbinden").font(.headline)
                            }
                            .frame(minHeight: TouchTarget.comfortable)
                        }
                    }
                }
                if case .done = session.phase {
                    Section {
                        Button("Erneut abgleichen") { session.syncAgain() }
                            .frame(minHeight: TouchTarget.minimum)
                    }
                }
            }
            .navigationTitle("Abgleich vor Ort")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() }.fontWeight(.bold) }
            }
            .onAppear { session.start() }
            .onDisappear { session.stop() }
            .alert(
                "Abgleich anfragen",
                isPresented: Binding(get: { session.invitation != nil }, set: { if !$0 { session.answerInvitation(false) } })
            ) {
                Button("Annehmen") { session.answerInvitation(true) }
                Button("Ablehnen", role: .cancel) { session.answerInvitation(false) }
            } message: {
                Text("„\(session.invitation?.name ?? "")“ möchte den Einsatz „\(session.invitation?.missionTitle ?? "")“ abgleichen. Beide Geräte erhalten danach alle Daten des Einsatzes.")
            }
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch session.phase {
        case .searching:
            Label("Bereit – suche iPads in der Nähe", systemImage: "dot.radiowaves.left.and.right")
        case .connecting(let name):
            Label("Verbinde mit \(name) …", systemImage: "link")
        case .exchanging(let name):
            Label("Gleiche ab mit \(name) …", systemImage: "arrow.triangle.2.circlepath")
        case .done(let name):
            VStack(alignment: .leading, spacing: 4) {
                Label("Abgeglichen mit \(name)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text(summary).font(.subheadline).foregroundStyle(.secondary)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    private var summary: String {
        let p = session.progress
        var parts = ["\(p.importedEvents) Änderungen übernommen"]
        if p.filesReceived > 0 { parts.append("\(p.filesReceived) Dateien erhalten") }
        if p.filesSent > 0 { parts.append("\(p.filesSent) Dateien gesendet") }
        if p.filesRejected > 0 { parts.append("\(p.filesRejected) Dateien beschädigt") }
        return parts.joined(separator: " · ")
    }
}
