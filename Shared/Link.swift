import CryptoKit
import Foundation
import Network

/// The iPad-to-Apple TV protocol.
///
/// iPad sends `show`. If the TV has the image, it displays it and replies `shown`.
/// If the TV does not have it, the TV replies `need` and the iPad sends `put` with the bytes.
/// This also recovers on its own when tvOS purges the cache.
enum Link {
    static let serviceType = "_mirage-arcane._tcp"
    static let serviceName = "Mirage Arcane TV"
    static let maxFrame = 64 * 1024 * 1024

    /// Image names come from the network and end up in file paths, so only a SHA-256 hex string is accepted.
    static func isValidHash(_ hash: String) -> Bool {
        hash.utf8.count == 64 && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func hash(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        return NWParameters(tls: nil, tcp: tcp)
    }
}

struct LinkMessage: Codable {
    enum Kind: String, Codable { case show, need, put, shown }
    var kind: Kind
    var hash: String
    var fade: Double?
}

/// Length-prefixed frames over one TCP connection: [len][JSON][len][binary].
final class FrameChannel: @unchecked Sendable {
    let connection: NWConnection
    var onMessage: ((LinkMessage, Data) -> Void)?
    var onState: ((NWConnection.State) -> Void)?

    init(_ connection: NWConnection) { self.connection = connection }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in self?.onState?(state) }
        connection.start(queue: .main)
        readFrame()
    }

    func cancel() { connection.cancel() }

    func send(_ message: LinkMessage, payload: Data = Data()) {
        guard let json = try? JSONEncoder().encode(message) else { return }
        var frame = Data()
        frame.append(Self.encode(json.count))
        frame.append(json)
        frame.append(Self.encode(payload.count))
        frame.append(payload)
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    private static func encode(_ value: Int) -> Data {
        withUnsafeBytes(of: UInt32(value).bigEndian) { Data($0) }
    }

    private static func decode(_ data: Data) -> Int {
        data.reduce(0) { ($0 << 8) | Int($1) }
    }

    private func readFrame() {
        readSized { [weak self] json in
            self?.readSized { [weak self] payload in
                guard let self else { return }
                if let message = try? JSONDecoder().decode(LinkMessage.self, from: json) {
                    self.onMessage?(message, payload)
                }
                self.readFrame()
            }
        }
    }

    private func readSized(_ done: @escaping (Data) -> Void) {
        read(4) { [weak self] header in
            guard let self else { return }
            let size = Self.decode(header)
            guard size <= Link.maxFrame else { self.connection.cancel(); return }
            self.read(size, done)
        }
    }

    private func read(_ count: Int, _ done: @escaping (Data) -> Void) {
        guard count > 0 else { done(Data()); return }
        connection.receive(minimumIncompleteLength: count, maximumLength: count) { [weak self] data, _, _, _ in
            guard let data, data.count == count else { self?.connection.cancel(); return }
            done(data)
        }
    }
}
