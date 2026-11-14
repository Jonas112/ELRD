import Foundation
import ELRDDomain

/// Fehler beim Abfragen des ELRD-Backends – mit Texten für die Oberfläche.
enum AlamosClientError: LocalizedError, Equatable {
    case notConfigured
    case invalidURL
    case unauthorized
    case server(Int)
    case unreadable
    case network(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Adresse oder App-Schlüssel fehlen (Einstellungen › Alamos FE2)."
        case .invalidURL: "Die Adresse des Backends ist ungültig."
        case .unauthorized: "Der App-Schlüssel wird nicht angenommen. Bitte in den Einstellungen prüfen."
        case .server(let code): "Das Backend antwortet mit Fehler \(code)."
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
