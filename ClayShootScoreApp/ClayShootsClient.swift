//
//  ClayShootsClient.swift
//
//  Sends finished shoots to the Clay Shoots web app through its JSON API.
//

import CryptoKit
import Foundation
import Security

/// The body accepted by `POST /api/v1/shoots`.
nonisolated struct ShootUpload: Encodable, Sendable {
    nonisolated struct Entry: Encodable, Sendable {
        let name: String
        let email: String?
        let scores: [Int]
        /// One string per stand: "1" hit, "0" miss, "-" not shot.
        let patterns: [String]
    }

    let externalId: String
    let name: String
    let venue: String?
    let date: String
    let time: String
    let stands: Int
    let targetsPerStand: Int
    /// False while the shoot is still being scored; the server emails and posts only when true.
    let complete: Bool
    let shooters: [Entry]
}

nonisolated struct ShootUploadReceipt: Decodable, Sendable {
    let id: Int
    let url: String
}

/// A registered shooter from the club's roster on the website.
nonisolated struct RosterShooter: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
    let email: String
    /// "member" or "guest".
    let kind: String
    var isAdmin: Bool? = false
    var verified: Bool? = false
    var isGuest: Bool { kind != "member" }
}

nonisolated enum ClayShootsError: LocalizedError {
    case notConfigured
    case invalidURL
    case invalidKey
    case subscriptionRequired
    case validation([String])
    case server(Int)
    case network(String)
    case untrustedServer(String)
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
        case .untrustedServer(let message): message
        case .nothingToSend: "Add at least one shooter before sending."
        }
    }
}

nonisolated struct ClayShootsClient: Sendable {
    let baseURL: URL
    let apiKey: String
    /// SHA-256 (hex) of the server's public key. When set, only a server holding that key is trusted.
    var pinnedFingerprint: String = ""
    /// Testing only: accept any certificate (including self-signed) when no fingerprint is set.
    var trustSelfSigned: Bool = false

    /// Turns what the user typed into a base URL. Only encrypted connections are used:
    /// a missing scheme or `http://` becomes `https://`.
    static func normalisedURL(_ text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") {
            trimmed = "https://" + trimmed.dropFirst("http://".count)
        } else if !lower.hasPrefix("https://") {
            trimmed = "https://" + trimmed
        }
        guard let url = URL(string: trimmed), url.scheme == "https", url.host() != nil else { return nil }
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

    /// The club's current members and guests. Expired members are never returned.
    func fetchRoster() async throws -> [RosterShooter] {
        var request = URLRequest(url: baseURL.appending(path: "api/v1/shooters"))
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await perform(request)
        try Self.check(response, data: data, expected: 200)
        struct Reply: Decodable { let shooters: [RosterShooter] }
        return try JSONDecoder().decode(Reply.self, from: data).shooters
    }

    /// Adds a new shooter to the club's roster as a member or guest and returns the saved entry.
    func addRosterShooter(name: String, email: String, isMember: Bool, isAdmin: Bool) async throws -> RosterShooter {
        var request = URLRequest(url: baseURL.appending(path: "api/v1/shooters"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct NewShooter: Encodable { let name: String; let email: String; let kind: String; let isAdmin: Bool }
        request.httpBody = try JSONEncoder().encode(NewShooter(name: name, email: email, kind: isMember ? "member" : "guest", isAdmin: isMember && isAdmin))
        let (data, response) = try await perform(request)
        guard response.statusCode == 200 || response.statusCode == 201 else {
            if response.statusCode == 409 { throw ClayShootsError.validation(["that shooter's membership has expired"]) }
            try Self.check(response, data: data, expected: 201)
            throw ClayShootsError.server(response.statusCode)
        }
        struct Reply: Decodable { let shooter: RosterShooter }
        return try JSONDecoder().decode(Reply.self, from: data).shooter
    }

    func send(_ upload: ShootUpload) async throws -> ShootUploadReceipt {
        try await send(body: JSONEncoder().encode(upload))
    }

    func send(body: Data) async throws -> ShootUploadReceipt {
        var request = URLRequest(url: baseURL.appending(path: "api/v1/shoots"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await perform(request)
        try Self.check(response, data: data, expected: 201)
        return try JSONDecoder().decode(ShootUploadReceipt.self, from: data)
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard request.url?.scheme == "https" else {
            throw ClayShootsError.untrustedServer("Refusing to send over an unencrypted connection.")
        }
        let pinned = PinnedSession.shared(for: pinnedFingerprint, trustAny: trustSelfSigned)
        do {
            let (data, response) = try await pinned.session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ClayShootsError.server(0) }
            return (data, http)
        } catch let error as ClayShootsError {
            throw error
        } catch {
            if pinned.takePinFailure() {
                throw ClayShootsError.untrustedServer("The server's identity does not match the fingerprint in Server Settings. Nothing was sent.")
            }
            if let urlError = error as? URLError {
                switch urlError.code {
                case .serverCertificateUntrusted, .serverCertificateHasUnknownRoot, .serverCertificateHasBadDate,
                     .serverCertificateNotYetValid, .secureConnectionFailed, .clientCertificateRejected:
                    throw ClayShootsError.untrustedServer("The server's certificate is not trusted. If it is self-signed, enter its key fingerprint in Server Settings (or switch on the testing option). Nothing was sent.")
                default: break
                }
            }
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
    private static let pinKey = "clayShootsServerPin"
    private static let trustKey = "clayShootsTrustSelfSigned"
    private static let keychainService = "ClayShootsAPIKey"

    var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: Self.urlKey) }
    }

    var apiKey: String {
        didSet { Self.storeKey(apiKey) }
    }

    /// Fingerprint of the server's key, shown by the server when it starts. Not secret.
    var pinnedFingerprint: String {
        didSet { UserDefaults.standard.set(pinnedFingerprint, forKey: Self.pinKey) }
    }

    /// Testing only: lets the app connect to a server with a self-signed certificate without a fingerprint.
    var trustSelfSigned: Bool {
        didSet { UserDefaults.standard.set(trustSelfSigned, forKey: Self.trustKey) }
    }

    init() {
        trustSelfSigned = UserDefaults.standard.bool(forKey: Self.trustKey)
        pinnedFingerprint = UserDefaults.standard.string(forKey: Self.pinKey) ?? ""
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
        struct Config: Decodable { let serverURL: String; let apiKey: String; let fingerprint: String? }
        guard let config = try? JSONDecoder().decode(Config.self, from: data) else { return }
        serverURL = config.serverURL
        apiKey = config.apiKey
        if let fingerprint = config.fingerprint { pinnedFingerprint = fingerprint }
    }

    var client: ClayShootsClient? {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, let url = ClayShootsClient.normalisedURL(serverURL) else { return nil }
        return ClayShootsClient(baseURL: url, apiKey: key, pinnedFingerprint: pinnedFingerprint, trustSelfSigned: trustSelfSigned)
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
    /// True once at least one target has been scored.
    var hasAnyScore: Bool {
        shooters.contains { $0.scores.contains { $0.contains { $0 >= 0 } } }
    }

    /// Builds the API payload from the current scoresheet. Targets not yet shot
    /// count as misses, and blank or repeated shooter names are made unique because
    /// the server requires distinct names.
    func makeUpload(externalId: String, forceComplete: Bool = false) -> ShootUpload? {
        guard !shooters.isEmpty else { return nil }
        let targets = shooters.first?.scores.first?.count ?? Self.targetsPerStand
        var used = Set<String>()
        let entries = shooters.enumerated().map { index, shooter -> ShootUpload.Entry in
            var base = shooter.name.trimmingCharacters(in: .whitespacesAndNewlines).capitalized
            if base.isEmpty { base = "Shooter \(index + 1)" }
            base = String(base.prefix(70))
            var name = base
            var n = 2
            while used.contains(name.lowercased()) { name = "\(base) \(n)"; n += 1 }
            used.insert(name.lowercased())
            let scores = (0..<numberOfStands).map { stand in
                shooter.scores.indices.contains(stand) ? min(shooter.standTotal(stand), targets) : 0
            }
            let patterns = (0..<numberOfStands).map { stand -> String in
                let row = shooter.scores.indices.contains(stand) ? shooter.scores[stand] : []
                return String((0..<targets).map { t -> Character in
                    let v = t < row.count ? row[t] : -1
                    return v > 0 ? "1" : (v == 0 ? "0" : "-")
                })
            }
            return .init(name: name, email: email(for: shooter.name), scores: scores, patterns: patterns)
        }
        let c = Calendar.current.dateComponents([.year, .month, .day], from: shootStart)
        let date = String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
        let name = shootName.trimmingCharacters(in: .whitespacesAndNewlines)
        return ShootUpload(
            externalId: externalId,
            name: String((name.isEmpty ? "Shoot" : name).prefix(120)),
            venue: venue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : String(venue.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)),
            date: date,
            time: String(format: "%02d:%02d", Calendar.current.component(.hour, from: shootStart), Calendar.current.component(.minute, from: shootStart)),
            stands: numberOfStands,
            targetsPerStand: targets,
            complete: isComplete || forceComplete,
            shooters: entries
        )
    }

    /// True while some target on the scoresheet has not been scored.
    var hasUnscoredTargets: Bool {
        shooters.contains { !$0.isComplete }
    }
}

/// Uploads waiting for the server, kept on disk (latest version per shoot) so
/// nothing is lost if the connection drops or the app is closed.
enum UploadOutbox {
    private static let key = "uploadOutbox"
    private static var all: [String: Data] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: Data] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
    static var pending: [(id: String, body: Data)] { all.map { ($0.key, $0.value) } }
    static var count: Int { all.count }
    static func save(id: String, body: Data) { all[id] = body }
    static func clear(id: String, ifBody body: Data) {
        if all[id] == body { all[id] = nil }
    }
}


/// One URLSession per pin value. It never stores cookies, caches or credentials, accepts TLS 1.2 or
/// later only, refuses redirects, and, when a fingerprint is set, trusts only a server whose public
/// key hashes to it (so a self-signed server is safe and an impostor is rejected).
nonisolated final class PinnedSession: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: PinnedSession] = [:]

    static func normalised(_ text: String) -> String {
        text.lowercased().filter { $0.isHexDigit }
    }

    static func shared(for fingerprint: String, trustAny: Bool = false) -> PinnedSession {
        let pin = normalised(fingerprint)
        let cacheKey = trustAny ? pin + "|any" : pin
        lock.lock(); defer { lock.unlock() }
        if let existing = cache[cacheKey] { return existing }
        let made = PinnedSession(pin: pin, trustAny: trustAny)
        cache[cacheKey] = made
        return made
    }

    private let pin: String
    private let trustAny: Bool
    private let stateLock = NSLock()
    private var pinFailed = false
    private(set) var session: URLSession!

    private init(pin: String, trustAny: Bool) {
        self.pin = pin
        self.trustAny = trustAny
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCredentialStorage = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func takePinFailure() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        let failed = pinFailed
        pinFailed = false
        return failed
    }

    private func markFailure() {
        stateLock.lock(); pinFailed = true; stateLock.unlock()
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        // No pin: normally the certificate must chain to a trusted authority and match the host name.
        // With the testing switch on, any certificate is accepted (still encrypted, but not authenticated).
        guard !pin.isEmpty else {
            if trustAny { completionHandler(.useCredential, URLCredential(trust: trust)) }
            else { completionHandler(.performDefaultHandling, nil) }
            return
        }
        if let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
           let key = SecCertificateCopyKey(leaf),
           let raw = SecKeyCopyExternalRepresentation(key, nil) as Data?,
           Self.constantTimeEqual(Self.hex(SHA256.hash(data: raw)), pin) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            markFailure()
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    // An authenticated request is never followed to another address.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
