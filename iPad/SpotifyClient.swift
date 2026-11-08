import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

struct SpotifyDevice: Decodable, Identifiable, Hashable {
    let id: String?
    let name: String
    let type: String
    let is_active: Bool
    var stableID: String { id ?? name }
}

struct SpotifyPlaylist: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let uri: String
}

@MainActor
final class SpotifyClient: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let redirectURI = "mirage-arcane://spotify-callback"
    private static let scopes = "user-read-playback-state user-modify-playback-state playlist-read-private playlist-read-collaborative"

    var clientID: String?
    var log: (String) -> Void = { _ in }

    private var accessToken: String?
    private var expiry = Date.distantPast
    private var refreshToken: String? = Keychain.get("spotify.refresh")
    private var webSession: ASWebAuthenticationSession?

    var isLoggedIn: Bool { refreshToken != nil }

    func logOut() {
        refreshToken = nil
        accessToken = nil
        Keychain.set(nil, for: "spotify.refresh")
    }

    /// Spike only: accepts a token obtained outside the app, for test runs with no login UI.
    func importRefreshToken(_ token: String) {
        refreshToken = token
        accessToken = nil
        expiry = .distantPast
        Keychain.set(token, for: "spotify.refresh")
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
        }
    }

    // MARK: Login (OAuth with PKCE, so the app holds no secret)

    func logIn() async throws {
        guard let clientID, !clientID.isEmpty else { throw AppError("Enter the Spotify Client ID first.") }
        let verifier = (0..<64).map { _ in
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".randomElement()!
        }.map(String.init).joined()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "scope", value: Self.scopes),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge),
        ]

        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: components.url!, callbackURLScheme: "mirage-arcane") { url, error in
                if let url { continuation.resume(returning: url) }
                else { continuation.resume(throwing: error ?? AppError("Login was cancelled.")) }
            }
            session.presentationContextProvider = self
            webSession = session
            session.start()
        }
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems
        guard let code = items?.first(where: { $0.name == "code" })?.value else {
            let reason = items?.first(where: { $0.name == "error" })?.value ?? "no code"
            throw AppError("Spotify login failed: \(reason)")
        }
        try await token(["grant_type": "authorization_code", "code": code,
                         "redirect_uri": Self.redirectURI, "client_id": clientID, "code_verifier": verifier])
    }

    private func token(_ form: [String: String]) async throws {
        struct Reply: Decodable { let access_token: String; let expires_in: Double; let refresh_token: String? }
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        // URLComponents leaves "+" unescaped, and form decoding would read it as a space.
        request.httpBody = body.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AppError("Spotify token error: \(String(decoding: data, as: UTF8.self))")
        }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        accessToken = reply.access_token
        expiry = Date().addingTimeInterval(reply.expires_in - 60)
        if let refresh = reply.refresh_token {
            refreshToken = refresh
            Keychain.set(refresh, for: "spotify.refresh")
        }
    }

    private func validToken(force: Bool = false) async throws -> String {
        if !force, let accessToken, Date() < expiry { return accessToken }
        guard let refreshToken, let clientID else { throw AppError("Log in to Spotify first.") }
        try await token(["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": clientID])
        return accessToken!
    }

    // MARK: Web API

    private func call(_ method: String, _ path: String, query: [String: String] = [:], json: Any? = nil) async throws -> (Data, Int) {
        var components = URLComponents(string: "https://api.spotify.com/v1\(path)")!
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var forceRefresh = false
        while true {
            var request = URLRequest(url: components.url!, timeoutInterval: 10)
            request.httpMethod = method
            request.setValue("Bearer \(try await validToken(force: forceRefresh))", forHTTPHeaderField: "Authorization")
            if let json {
                request.httpBody = try JSONSerialization.data(withJSONObject: json)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            } else if method == "PUT" {
                request.httpBody = Data()
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401, !forceRefresh {
                forceRefresh = true
                continue
            }
            return (data, status)
        }
    }

    /// Runs a player command with retries. Returns nil on success, or the last error text.
    @discardableResult
    private func command(_ label: String, _ method: String, _ path: String,
                         query: [String: String] = [:], json: Any? = nil, attempts: Int = 3) async throws -> String? {
        var last = ""
        for attempt in 1...attempts {
            let started = Date()
            let (data, status) = try await call(method, path, query: query, json: json)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            log("\(label): HTTP \(status), \(ms) ms, attempt \(attempt)")
            if (200..<300).contains(status) { return nil }
            last = "HTTP \(status) \(String(decoding: data, as: UTF8.self))"
            guard status == 404 || status == 429 || status >= 500, attempt < attempts else { break }
            try await Task.sleep(for: .milliseconds(500 * attempt * attempt))
        }
        log("\(label) failed: \(last)")
        return last
    }

    func devices() async throws -> [SpotifyDevice] {
        struct Reply: Decodable { let devices: [SpotifyDevice] }
        let (data, status) = try await call("GET", "/me/player/devices")
        guard status == 200 else { throw AppError("Device list: HTTP \(status) \(String(decoding: data, as: UTF8.self))") }
        return try JSONDecoder().decode(Reply.self, from: data).devices
    }

    func playlists() async throws -> [SpotifyPlaylist] {
        // Spotify can return null entries in this list, so decode each one as optional.
        struct Reply: Decodable { let items: [SpotifyPlaylist?]; let next: String? }
        var result: [SpotifyPlaylist] = []
        var offset = 0
        while offset < 500 {
            let (data, status) = try await call("GET", "/me/playlists", query: ["limit": "50", "offset": "\(offset)"])
            guard status == 200 else { throw AppError("Playlists: HTTP \(status) \(String(decoding: data, as: UTF8.self))") }
            let reply = try JSONDecoder().decode(Reply.self, from: data)
            result += reply.items.compactMap { $0 }
            guard reply.next != nil else { break }
            offset += 50
        }
        return result
    }

    /// Spotify does not guarantee order between player calls, so each step waits for the previous one.
    func play(contextURI: String, deviceID: String, deviceName: String, shuffle: Bool, volume: Int?) async throws {
        let visible = try await devices()
        log("Visible players: " + (visible.isEmpty ? "none" : visible.map { "\($0.name)\($0.is_active ? " (active)" : "")" }.joined(separator: ", ")))
        guard let target = visible.first(where: { $0.id == deviceID }) ?? visible.first(where: { $0.name == deviceName }),
              let id = target.id else {
            throw AppError("\(deviceName) is not visible. Open Spotify on it and press play once.")
        }
        if !target.is_active {
            if let error = try await command("Transfer", "PUT", "/me/player", json: ["device_ids": [id], "play": false]) {
                throw AppError("Transfer failed: \(error)")
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        if let volume {
            try await command("Volume", "PUT", "/me/player/volume", query: ["volume_percent": "\(volume)", "device_id": id], attempts: 1)
        }
        if let error = try await command("Play", "PUT", "/me/player/play", query: ["device_id": id], json: ["context_uri": contextURI]) {
            throw AppError("Play failed: \(error)")
        }
        // Spotify rejects shuffle with 403 until a context is playing, so it must come after play.
        try await Task.sleep(for: .milliseconds(400))
        let shuffleError = try await command("Shuffle", "PUT", "/me/player/shuffle", query: ["state": shuffle ? "true" : "false", "device_id": id])
        if shuffle, shuffleError == nil {
            // The first track was chosen before shuffle was on, so move to a shuffled one.
            try await command("Next", "POST", "/me/player/next", query: ["device_id": id], attempts: 1)
        }
    }
}
