//
//  ClayShootsClient.swift
//
//  Sends finished shoots to the Clay Shoots web app through its JSON API.
//

import Foundation
import Security

/// The body accepted by `POST /api/v1/shoots`.
nonisolated struct ShootUpload: Encodable, Sendable {
    nonisolated struct Entry: Encodable, Sendable {
        let name: String
        let scores: [Int]
    }

    let externalId: String
    let name: String
    let venue: String?
    let date: String
    let stands: Int
    let targetsPerStand: Int
    let shooters: [Entry]
}

nonisolated struct ShootUploadReceipt: Decodable, Sendable {
    let id: Int
    let url: String
}

nonisolated enum ClayShootsError: LocalizedError {
    case notConfigured
    case invalidURL
    case invalidKey
    case subscriptionRequired
    case validation([String])
    case server(Int)
    case network(String)
    case nothingToSend

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Enter the server address and API key first."
        case .invalidURL: "The server address is not a valid web address."
        case .invalidKey: "The server rejected the API key. Generate a new one on the dashboard."
        case .subscriptionRequired: "The Clay Shoots account needs an active subscription."
        case .validation(let details): "The server rejected the results: " + details.joined(separator: "; ")
        case .server(let code): "The server returned an error (\(code))."
        case .network(let message): "Could not reach the server: \(message)"
        case .nothingToSend: "Add at least one shooter before sending."
        }
    }
}

nonisolated struct ClayShootsClient: Sendable {
    let baseURL: URL
    let apiKey: String

    /// Turns what the user typed into a base URL, adding http:// when it is missing.
    static func normalisedURL(_ text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.lowercased().hasPrefix("http://") && !trimmed.lowercased().hasPrefix("https://") {
            trimmed = "http://" + trimmed
        }
        guard let url = URL(string: trimmed), url.host() != nil else { return nil }
        return url
    }

    /// Confirms the address and key work, returning the club name.
    func checkConnection() async throws -> String {
        var request = URLRequest(url: baseURL.appending(path: "api/v1/ping"))
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await perform(request)
        try Self.check(response, data: data, expected: 200)
        struct Ping: Decodable { let club: String }
        return (try? JSONDecoder().decode(Ping.self, from: data))?.club ?? "your club"
    }

    func send(_ upload: ShootUpload) async throws -> ShootUploadReceipt {
        var request = URLRequest(url: baseURL.appending(path: "api/v1/shoots"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(upload)
        let (data, response) = try await perform(request)
        try Self.check(response, data: data, expected: 201)
        return try JSONDecoder().decode(ShootUploadReceipt.self, from: data)
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ClayShootsError.server(0) }
            return (data, http)
        } catch let error as ClayShootsError {
            throw error
        } catch {
            throw ClayShootsError.network(error.localizedDescription)
        }
    }

    private static func check(_ response: HTTPURLResponse, data: Data, expected: Int) throws {
        guard response.statusCode != expected else { return }
        struct Failure: Decodable { let error: String?; let details: [String]? }
        let failure = try? JSONDecoder().decode(Failure.self, from: data)
        switch response.statusCode {
        case 401: throw ClayShootsError.invalidKey
        case 402: throw ClayShootsError.subscriptionRequired
        case 400: throw ClayShootsError.validation(failure?.details ?? [failure?.error ?? "invalid data"])
        default: throw ClayShootsError.server(response.statusCode)
        }
    }
}

/// The server address (user defaults) and API key (Keychain) the app sends to.
@Observable
final class ClayShootsSettings {
    private static let urlKey = "clayShootsServerURL"
    private static let keychainService = "ClayShootsAPIKey"

    var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: Self.urlKey) }
    }

    var apiKey: String {
        didSet { Self.storeKey(apiKey) }
    }

    init() {
        serverURL = UserDefaults.standard.string(forKey: Self.urlKey) ?? ""
        apiKey = Self.loadKey()
        importPendingConfig()
    }

    /// Picks up a `clayshoots-config.json` dropped into the app's Documents folder
    /// (server address and API key), stores it, then deletes the file.
    private func importPendingConfig() {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let file = dir.appending(path: "clayshoots-config.json")
        guard let data = try? Data(contentsOf: file) else { return }
        defer { try? FileManager.default.removeItem(at: file) }
        struct Config: Decodable { let serverURL: String; let apiKey: String }
        guard let config = try? JSONDecoder().decode(Config.self, from: data) else { return }
        serverURL = config.serverURL
        apiKey = config.apiKey
    }

    var client: ClayShootsClient? {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, let url = ClayShootsClient.normalisedURL(serverURL) else { return nil }
        return ClayShootsClient(baseURL: url, apiKey: key)
    }

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService]
    }

    private static func loadKey() -> String {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func storeKey(_ key: String) {
        SecItemDelete(query as CFDictionary)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var q = query
        q[kSecValueData as String] = Data(trimmed.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)
    }
}

extension ShootViewModel {
    /// Builds the API payload from the current scoresheet. Targets not yet shot
    /// count as misses, and blank or repeated shooter names are made unique because
    /// the server requires distinct names.
    func makeUpload(externalId: String) -> ShootUpload? {
        guard !shooters.isEmpty else { return nil }
        let targets = shooters.first?.scores.first?.count ?? Self.targetsPerStand
        var used = Set<String>()
        let entries = shooters.enumerated().map { index, shooter -> ShootUpload.Entry in
            var base = shooter.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if base.isEmpty { base = "Shooter \(index + 1)" }
            base = String(base.prefix(70))
            var name = base
            var n = 2
            while used.contains(name.lowercased()) { name = "\(base) \(n)"; n += 1 }
            used.insert(name.lowercased())
            let scores = (0..<numberOfStands).map { stand in
                shooter.scores.indices.contains(stand) ? min(shooter.standTotal(stand), targets) : 0
            }
            return .init(name: name, scores: scores)
        }
        let c = Calendar.current.dateComponents([.year, .month, .day], from: .now)
        let date = String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
        let name = shootName.trimmingCharacters(in: .whitespacesAndNewlines)
        return ShootUpload(
            externalId: externalId,
            name: String((name.isEmpty ? "Shoot" : name).prefix(120)),
            venue: venue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : String(venue.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)),
            date: date,
            stands: numberOfStands,
            targetsPerStand: targets,
            shooters: entries
        )
    }

    /// True while some target on the scoresheet has not been scored.
    var hasUnscoredTargets: Bool {
        shooters.contains { !$0.isComplete }
    }
}
