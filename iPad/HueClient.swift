import Foundation
import Network

struct HueScene: Identifiable, Hashable {
    let id: String
    let name: String
    let room: String
}

/// The bridge presents a certificate from Hue's own CA.
/// PROTOTYPE: this accepts any certificate. The real app must pin the Hue root CA.
private final class BridgeTrust: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

final class HueClient {
    var bridgeIP: String?
    var appKey: String?

    private let session = URLSession(configuration: .ephemeral, delegate: BridgeTrust(), delegateQueue: nil)

    var isPaired: Bool { bridgeIP != nil && appKey != nil }

    /// Finds the first bridge on the network through Bonjour and returns its IP address.
    static func discover(timeout: Duration = .seconds(6)) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await resolveFirstBridge() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw AppError("No Hue Bridge found on this network.")
            }
            let ip = try await group.next()!
            group.cancelAll()
            return ip
        }
    }

    private static func resolveFirstBridge() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_hue._tcp", domain: nil), using: .tcp)
            var finished = false
            browser.browseResultsChangedHandler = { results, _ in
                guard !finished, let result = results.first else { return }
                finished = true
                browser.cancel()
                // Prefer the .local name. App Transport Security refuses this bridge's certificate
                // when the address is an IP in a public range.
                if case .bonjour(let txt) = result.metadata, let id = txt["bridgeid"]?.lowercased(), id.count == 16, id.allSatisfy(\.isHexDigit) {
                    continuation.resume(returning: "\(id.prefix(6))\(id.suffix(6)).local")
                    return
                }
                let connection = NWConnection(to: result.endpoint, using: .tcp)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if case .hostPort(let host, _)? = connection.currentPath?.remoteEndpoint {
                            let text = "\(host)".split(separator: "%").first.map(String.init) ?? "\(host)"
                            continuation.resume(returning: text)
                        } else {
                            continuation.resume(throwing: AppError("Could not read the bridge address."))
                        }
                        connection.cancel()
                    case .failed(let error):
                        continuation.resume(throwing: error)
                    default: break
                    }
                }
                connection.start(queue: .main)
            }
            browser.start(queue: .main)
        }
    }

    private func request(_ method: String, _ path: String, json: Any? = nil) async throws -> Data {
        guard let bridgeIP, let url = URL(string: "https://\(bridgeIP)\(path)") else {
            throw AppError("No bridge address.")
        }
        var request = URLRequest(url: url, timeoutInterval: 6)
        request.httpMethod = method
        if let appKey { request.setValue(appKey, forHTTPHeaderField: "hue-application-key") }
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw AppError("Hue HTTP \(status): \(String(decoding: data, as: UTF8.self))")
        }
        return data
    }

    /// Call within about 30 seconds after the user presses the bridge button.
    func pair() async throws -> String {
        let saved = appKey
        appKey = nil
        defer { if appKey == nil { appKey = saved } }
        let body: [String: Any] = ["devicetype": "mirage_arcane#ipad", "generateclientkey": true]
        let data = try await request("POST", "/api", json: body)
        guard let first = (try JSONSerialization.jsonObject(with: data) as? [[String: Any]])?.first else {
            throw AppError("Unexpected bridge reply.")
        }
        if let success = first["success"] as? [String: Any], let key = success["username"] as? String {
            appKey = key
            return key
        }
        let description = (first["error"] as? [String: Any])?["description"] as? String
        throw AppError(description ?? "Pairing failed.")
    }

    func scenes() async throws -> [HueScene] {
        struct Owner: Decodable { let rid: String }
        struct Meta: Decodable { let name: String }
        struct SceneItem: Decodable { let id: String; let metadata: Meta; let group: Owner }
        struct GroupItem: Decodable { let id: String; let metadata: Meta }
        struct Page<T: Decodable>: Decodable { let data: [T] }

        let decoder = JSONDecoder()
        let rooms = try decoder.decode(Page<GroupItem>.self, from: await request("GET", "/clip/v2/resource/room"))
        let zones = try decoder.decode(Page<GroupItem>.self, from: await request("GET", "/clip/v2/resource/zone"))
        let names = Dictionary((rooms.data + zones.data).map { ($0.id, $0.metadata.name) }, uniquingKeysWith: { a, _ in a })
        let scenes = try decoder.decode(Page<SceneItem>.self, from: await request("GET", "/clip/v2/resource/scene"))
        return scenes.data
            .map { HueScene(id: $0.id, name: $0.metadata.name, room: names[$0.group.rid] ?? "Other") }
            .sorted { ($0.room, $0.name) < ($1.room, $1.name) }
    }

    func recall(sceneID: String, dynamic: Bool, fadeSeconds: Double) async throws {
        let recall: [String: Any] = dynamic
            ? ["action": "dynamic_palette"]
            : ["action": "active", "duration": Int(fadeSeconds * 1000)]
        _ = try await request("PUT", "/clip/v2/resource/scene/\(sceneID)", json: ["recall": recall])
    }
}
