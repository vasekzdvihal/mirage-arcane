import CryptoKit
import Foundation
import Security
import UIKit

struct Preset: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var name: String
    var locationId: String?
    var order: Int?
    var hueSceneID: String?
    var hueDynamic = false
    var playlistURI: String?
    var playlistName: String?
    var shuffle = true
    var volume: Int?
    var imageHash: String?
    var fadeSeconds: Double = 2
}

enum Channel: String, CaseIterable, Identifiable {
    case hue = "Hue", music = "Spotify", tv = "TV"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .hue: "lightbulb.fill"
        case .music: "music.note"
        case .tv: "tv.fill"
        }
    }
}

enum ChannelStatus: Equatable {
    case idle, working, skipped
    case ok(Int)
    case failed(String)
}

struct LogEntry: Identifiable {
    let id = UUID()
    let date = Date()
    let channel: String
    let text: String
}

struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum Keychain {
    private static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "miragearcane",
         kSecAttrAccount as String: key]
    }

    static func set(_ value: String?, for key: String) {
        SecItemDelete(query(key) as CFDictionary)
        guard let value else { return }
        var item = query(key)
        item[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        var item = query(key)
        item[kSecReturnData as String] = true
        var result: AnyObject?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Presets as JSON and images as content-addressed JPEGs in Documents.
enum Store {
    private static let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private static let presetsFile = documents.appendingPathComponent("presets.json")
    private static let imageDirectory: URL = {
        let url = documents.appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func loadPresets() -> [Preset]? {
        guard let data = try? Data(contentsOf: presetsFile) else { return nil }
        return try? JSONDecoder().decode([Preset].self, from: data)
    }

    static func save(_ presets: [Preset]) {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        try? data.write(to: presetsFile, options: .atomic)
    }

    static func imageData(_ hash: String) -> Data? {
        guard Link.isValidHash(hash) else { return nil }
        return try? Data(contentsOf: imageDirectory.appendingPathComponent("\(hash).jpg"))
    }

    static func write(_ data: Data, hash: String) {
        guard Link.isValidHash(hash) else { return }
        try? data.write(to: imageDirectory.appendingPathComponent("\(hash).jpg"), options: .atomic)
    }

    static func image(_ hash: String) -> UIImage? {
        imageData(hash).flatMap(UIImage.init(data:))
    }

    /// Fits the image inside 4K, stores it, and returns its hash.
    static func importImage(_ source: UIImage) -> String? {
        let longest = max(source.size.width, source.size.height)
        let scale = min(1, 3840 / longest)
        let size = CGSize(width: source.size.width * scale, height: source.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            source.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let jpeg = resized.jpegData(compressionQuality: 0.88) else { return nil }
        let hash = SHA256.hash(data: jpeg).map { String(format: "%02x", $0) }.joined()
        try? jpeg.write(to: imageDirectory.appendingPathComponent("\(hash).jpg"), options: .atomic)
        return hash
    }

    /// Placeholder artwork so the TV path can be tested with no assets.
    static func placeholder(title: String, top: UIColor, bottom: UIColor) -> UIImage {
        let size = CGSize(width: 1920, height: 1080)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let colors = [top.cgColor, bottom.cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
            context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont(name: "Georgia", size: 110) ?? UIFont.systemFont(ofSize: 110),
                .foregroundColor: UIColor.white.withAlphaComponent(0.85),
            ]
            let text = title as NSString
            let textSize = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2),
                      withAttributes: attributes)
        }
    }
}
