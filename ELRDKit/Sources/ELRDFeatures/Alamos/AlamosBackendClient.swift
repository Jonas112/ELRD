import CryptoKit
import Foundation
import ELRDDomain
import Security

/// Fehler beim Abfragen des ELRD-Backends – mit Texten für die Oberfläche.
enum AlamosClientError: LocalizedError, Equatable {
    case notConfigured
    case invalidURL
    case unauthorized
    case server(Int)
    case unreadable
    case network(String)
    /// Schritt 153: Zertifikat passt nicht zum eingetragenen Fingerabdruck.
    case certificateMismatch

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Adresse oder App-Schlüssel fehlen (Einstellungen › Alamos FE2)."
        case .invalidURL: "Die Adresse des Backends ist ungültig."
        case .unauthorized: "Der App-Schlüssel wird nicht angenommen. Bitte in den Einstellungen prüfen."
        case .server(let code): "Das Backend antwortet mit Fehler \(code)."
        case .certificateMismatch: "Das Zertifikat des Backends passt nicht zum eingetragenen Fingerabdruck. Fingerabdruck im Fenster des Backends prüfen."
        case .unreadable: "Die Antwort des Backends ist unlesbar (passt die Version?)."
        case .network(let text): text
        }
    }
}

/// Liest Einsätze aus dem ELRD-Backend (nur lesen, Schritt 140).
struct AlamosBackendClient: Sendable {
    let baseURL: URL
    let apiKey: String
    var session: URLSession = .shared
    /// Schritt 153: Fingerabdruck des erwarteten Zertifikats (selbst signiert).
    var pinnedFingerprint: String?

    init(baseURL: URL, apiKey: String, pinnedFingerprint: String? = nil) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.pinnedFingerprint = pinnedFingerprint
        if let pinnedFingerprint { session = PinnedSessions.session(for: pinnedFingerprint) }
    }

    func ping() async throws -> AlamosPing {
        try await get("api/v1/ping", query: [])
    }

    /// Alle Einsätze der Organisation (das Backend hält nur die letzten Stunden vor).
    func alarms(since: Date? = nil) async throws -> AlamosAlarmList {
        var query: [URLQueryItem] = []
        if let since { query.append(URLQueryItem(name: "since", value: AlamosJSON.format(since))) }
        return try await get("api/v1/alarms", query: query)
    }

    /// Schritt 144: Gerät für Push-Mitteilungen anmelden (Kennzeichen von Apple, hexadezimal).
    func registerDevice(token: String, environment: String) async throws -> AlamosDeviceRegistration {
        let body = try JSONEncoder().encode(["token": token, "environment": environment])
        return try await send("api/v1/devices", method: "POST", body: body)
    }

    /// Schritt 144: Gerät abmelden (Abruf aus oder anderer Schlüssel).
    func unregisterDevice(token: String) async throws {
        let _: Empty = try await send("api/v1/devices/\(token)", method: "DELETE", body: nil)
    }

    private struct Empty: Decodable {}

    private func get<Result: Decodable>(_ path: String, query: [URLQueryItem]) async throws -> Result {
        try await send(path, query: query, method: "GET", body: nil)
    }

    private func send<Result: Decodable>(_ path: String, query: [URLQueryItem] = [], method: String, body: Data?) async throws -> Result {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw AlamosClientError.invalidURL
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw AlamosClientError.invalidURL }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = method
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request)
        } catch let error as URLError {
            if pinnedFingerprint != nil, error.code == .cancelled || error.code == .serverCertificateUntrusted {
                throw AlamosClientError.certificateMismatch
            }
            throw AlamosClientError.network(Self.describe(error))
        }
        let (data, response) = result
        guard let http = response as? HTTPURLResponse else { throw AlamosClientError.unreadable }
        switch http.statusCode {
        case 200: break
        case 204 where Result.self == Empty.self: return try JSONDecoder().decode(Result.self, from: Data("{}".utf8))
        case 401, 403: throw AlamosClientError.unauthorized
        default: throw AlamosClientError.server(http.statusCode)
        }
        do {
            return try AlamosJSON.decoder().decode(Result.self, from: data)
        } catch {
            throw AlamosClientError.unreadable
        }
    }

    static func describe(_ error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost: "Keine Internetverbindung."
        case .timedOut: "Das Backend antwortet nicht (Zeitüberschreitung)."
        case .cannotFindHost, .dnsLookupFailed: "Adresse des Backends nicht gefunden."
        case .cannotConnectToHost: "Backend nicht erreichbar."
        case .appTransportSecurityRequiresSecureConnection: "iPadOS erlaubt für diese Adresse nur https://. http:// geht nur im eigenen Netz (192.168.…, 10.…, 172.16–31.…, Tailscale 100.64–127.…, Name ohne Punkt oder ….local)."
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
            "Zertifikat des Backends ungültig."
        default: "Verbindung fehlgeschlagen (\(error.code.rawValue))."
        }
    }
}

// MARK: - Zertifikat mit Fingerabdruck (Schritt 153)

/// Eine Sitzung je Fingerabdruck (Sitzungen mit Delegate werden nicht freigegeben, daher
/// nicht bei jedem Abruf neu anlegen).
enum PinnedSessions {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var sessions: [String: URLSession] = [:]

    static func session(for fingerprint: String) -> URLSession {
        lock.lock()
        defer { lock.unlock() }
        if let session = sessions[fingerprint] { return session }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: configuration, delegate: PinningDelegate(fingerprint: fingerprint), delegateQueue: nil)
        sessions[fingerprint] = session
        return session
    }
}

/// Vertraut genau dem Zertifikat mit dem eingetragenen SHA-256-Fingerabdruck – für das
/// selbst signierte Zertifikat des Python-Backends. Andere Zertifikate werden abgelehnt.
final class PinningDelegate: NSObject, URLSessionDelegate, Sendable {
    let fingerprint: String

    init(fingerprint: String) {
        self.fingerprint = fingerprint
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        guard Self.leafFingerprint(of: trust) == fingerprint else { return (.cancelAuthenticationChallenge, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }

    static func leafFingerprint(of trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { return nil }
        return fingerprint(of: SecCertificateCopyData(leaf) as Data)
    }

    /// SHA-256 der DER-Daten, 64 Hex-Zeichen groß.
    static func fingerprint(of der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined()
    }
}
