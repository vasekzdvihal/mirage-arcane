import Network
import Observation
import SwiftUI

@MainActor
@Observable
final class TVClient {
    var isConnected = false
    var log: (String) -> Void = { _ in }

    private var browser: NWBrowser?
    private var channel: FrameChannel?
    private var endpoints: [NWEndpoint] = []
    private var waiting: [String: CheckedContinuation<Void, Error>] = [:]

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: Link.serviceType, domain: nil), using: Link.parameters())
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated {
                self?.endpoints = results.map(\.endpoint)
                self?.connectIfNeeded()
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func connectIfNeeded() {
        guard channel == nil, let endpoint = endpoints.first else { return }
        let channel = FrameChannel(NWConnection(to: endpoint, using: Link.parameters()))
        self.channel = channel
        channel.onState = { [weak self, weak channel] state in
            MainActor.assumeIsolated {
                guard let self, self.channel === channel else { return }
                switch state {
                case .ready:
                    self.isConnected = true
                    self.log("Connected to Apple TV")
                case .failed, .cancelled:
                    self.dropped()
                default: break
                }
            }
        }
        channel.onMessage = { [weak self] message, _ in
            MainActor.assumeIsolated { self?.handle(message) }
        }
        channel.start()
    }

    private func dropped() {
        channel?.cancel()
        channel = nil
        isConnected = false
        log("Apple TV connection lost")
        for continuation in waiting.values { continuation.resume(throwing: AppError("Apple TV disconnected.")) }
        waiting.removeAll()
        Task {
            try? await Task.sleep(for: .seconds(1))
            connectIfNeeded()
        }
    }

    private func handle(_ message: LinkMessage) {
        switch message.kind {
        case .need:
            guard waiting[message.hash] != nil, let data = Store.imageData(message.hash) else { return }
            log("TV needs the image, sending \(data.count / 1024) KB")
            channel?.send(LinkMessage(kind: .put, hash: message.hash), payload: data)
        case .shown:
            waiting.removeValue(forKey: message.hash)?.resume()
        case .show, .put:
            break
        }
    }

    /// Returns when the TV has started showing the image.
    func show(hash: String, fade: Double) async throws {
        guard isConnected, let channel else { throw AppError("No screen connected. Start Screen Mirroring to the Apple TV.") }
        waiting.removeValue(forKey: hash)?.resume(throwing: AppError("Replaced by a newer request."))
        Task {
            try? await Task.sleep(for: .seconds(30))
            self.waiting.removeValue(forKey: hash)?.resume(throwing: AppError("Apple TV did not answer in time."))
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            waiting[hash] = continuation
            channel.send(LinkMessage(kind: .show, hash: hash, fade: fade))
        }
    }
}

@MainActor
@Observable
final class AppModel {
    var presets: [Preset] = []
    var statuses: [String: [Channel: ChannelStatus]] = [:]
    var activePresetID: String?
    var logEntries: [LogEntry] = []

    var bridgeIP = UserDefaults.standard.string(forKey: "hue.ip") ?? ""
    var hueScenes: [HueScene] = []
    var hueMessage = ""

    var spotifyClientID = UserDefaults.standard.string(forKey: "spotify.client") ?? ""
    var spotifyDevices: [SpotifyDevice] = []
    var playlists: [SpotifyPlaylist] = []
    var spotifyMessage = ""
    var outputID = UserDefaults.standard.string(forKey: "spotify.output.id") ?? ""
    var outputName = UserDefaults.standard.string(forKey: "spotify.output.name") ?? ""

    let tv = TVClient()
    let cloud = CloudStore()
    var selectedCampaignID: String?
    private let hue = HueClient()
    private let spotify = SpotifyClient()
    private var designsInProgress: Set<String> = []

    var huePaired: Bool { hue.isPaired }
    var spotifyLoggedIn: Bool { spotify.isLoggedIn }

    init() {
        hue.bridgeIP = bridgeIP.isEmpty ? nil : bridgeIP
        hue.appKey = Keychain.get("hue.key")
        spotify.clientID = spotifyClientID
        spotify.log = { [weak self] in self?.log("Spotify", $0) }
        tv.log = { [weak self] in self?.log("TV", $0) }
        presets = Store.loadPresets() ?? Self.seedPresets()
        Store.save(presets)
        tv.start()
        cloud.onScenes = { [weak self] scenes in
            guard let self else { return }
            self.presets = scenes
            Store.save(scenes)
            self.realizeLightDesigns()
        }
        cloud.localPresetsForFirstUpload = { [weak self] in self?.presets ?? [] }
        cloud.log = { [weak self] in self?.log("Cloud", $0) }
        Task {
            await refreshHue()
            await refreshSpotify()
        }
        // Spike hooks, so the Hue path can be driven from the command line.
        let arguments = CommandLine.arguments
        if arguments.contains("-pairHue") {
            Task {
                await findBridge()
                log("Hue", hueMessage)
                await autoPairHue()
            }
        }
        if let index = arguments.firstIndex(of: "-spotifyClient"), index + 1 < arguments.count {
            setClientID(arguments[index + 1])
        }
        let tokenFile = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("spotify-refresh.txt")
        if let token = try? String(contentsOf: tokenFile, encoding: .utf8) {
            spotify.importRefreshToken(token.trimmingCharacters(in: .whitespacesAndNewlines))
            try? FileManager.default.removeItem(at: tokenFile)
        }
        if arguments.contains("-loginSpotify") {
            Task { await spikeLoginSpotify() }
        }
        if let index = arguments.firstIndex(of: "-playSpotify"), index + 2 < arguments.count {
            let uri = arguments[index + 1], device = arguments[index + 2]
            Task { await spikePlay(uri: uri, deviceName: device) }
        }
        if let index = arguments.firstIndex(of: "-fireHueScene"), index + 1 < arguments.count {
            let sceneID = arguments[index + 1]
            Task { await fireHueScene(sceneID) }
        }
        if CommandLine.arguments.contains("-fireFirstPreset") {
            Task {
                try? await Task.sleep(for: .seconds(4))
                if let first = presets.first { fire(first) }
            }
        }
    }

    private static func seedPresets() -> [Preset] {
        let seeds: [(String, UIColor, UIColor)] = [
            ("Barovia Forest", UIColor(red: 0.05, green: 0.16, blue: 0.13, alpha: 1), UIColor(red: 0.02, green: 0.04, blue: 0.06, alpha: 1)),
            ("Ravenloft Entry", UIColor(red: 0.30, green: 0.05, blue: 0.08, alpha: 1), UIColor(red: 0.04, green: 0.02, blue: 0.05, alpha: 1)),
            ("Temple", UIColor(red: 0.42, green: 0.30, blue: 0.12, alpha: 1), UIColor(red: 0.08, green: 0.05, blue: 0.10, alpha: 1)),
        ]
        return seeds.map { name, top, bottom in
            Preset(name: name, imageHash: Store.importImage(Store.placeholder(title: name, top: top, bottom: bottom)))
        }
    }

    func log(_ channel: String, _ text: String) {
        logEntries.append(LogEntry(channel: channel, text: text))
        if logEntries.count > 500 { logEntries.removeFirst(100) }
    }

    var logText: String {
        let format = Date.FormatStyle().hour().minute().second()
        return logEntries.map { "\($0.date.formatted(format)) [\($0.channel)] \($0.text)" }.joined(separator: "\n")
    }

    // MARK: Presets

    func save(_ preset: Preset) {
        if let index = presets.firstIndex(where: { $0.id == preset.id }) { presets[index] = preset }
        else { presets.append(preset) }
        Store.save(presets)
        cloud.save(preset)
    }

    func delete(_ preset: Preset) {
        presets.removeAll { $0.id == preset.id }
        Store.save(presets)
        cloud.delete(preset)
    }

    var selectedCampaign: Campaign? {
        cloud.campaigns.first { $0.id == selectedCampaignID } ?? cloud.campaigns.first
    }

    /// Scenes grouped by location for the selected campaign. Without cloud data, one flat group.
    var sections: [(title: String?, presets: [Preset])] {
        guard let campaign = selectedCampaign else { return [(nil, presets)] }
        let locations = cloud.locations.filter { $0.campaignId == campaign.id }
        let ids = Set(cloud.locations.map(\.id))
        var result: [(title: String?, presets: [Preset])] = locations.map { location in
            (location.name, presets.filter { $0.locationId == location.id })
        }
        let unsorted = presets.filter { $0.locationId.map { !ids.contains($0) } ?? true }
        if !unsorted.isEmpty { result.append(("Unsorted", unsorted)) }
        return result
    }

    /// Each system runs on its own, so one failure never blocks the other two.
    func fire(_ preset: Preset) {
        activePresetID = preset.id
        log("Fire", "=== \(preset.name) ===")
        run(.hue, preset, enabled: preset.hueSceneID != nil && hue.isPaired) { [hue] in
            try await hue.recall(sceneID: preset.hueSceneID!, dynamic: preset.hueDynamic, fadeSeconds: preset.fadeSeconds)
        }
        run(.music, preset, enabled: preset.playlistURI != nil && spotify.isLoggedIn) { [self] in
            guard !outputName.isEmpty else { throw AppError("Choose a music output in Setup.") }
            try await spotify.play(contextURI: preset.playlistURI!, deviceID: outputID, deviceName: outputName,
                                   shuffle: preset.shuffle, volume: preset.volume)
        }
        run(.tv, preset, enabled: preset.imageHash != nil) { [tv] in
            if ExternalStage.shared.isConnected {
                try await ExternalStage.shared.show(hash: preset.imageHash!, fade: preset.fadeSeconds)
            } else {
                try await tv.show(hash: preset.imageHash!, fade: preset.fadeSeconds)
            }
        }
    }

    private func run(_ channel: Channel, _ preset: Preset, enabled: Bool, _ action: @escaping @MainActor () async throws -> Void) {
        guard enabled else {
            statuses[preset.id, default: [:]][channel] = .skipped
            return
        }
        statuses[preset.id, default: [:]][channel] = .working
        Task {
            let started = Date()
            do {
                try await action()
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                statuses[preset.id, default: [:]][channel] = .ok(ms)
                log(channel.rawValue, "OK in \(ms) ms")
            } catch {
                statuses[preset.id, default: [:]][channel] = .failed(error.localizedDescription)
                log(channel.rawValue, "FAILED: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Spike hooks

    private func writeSpikeStatus(_ text: String) {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("spike-status.txt")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Retries pairing for 5 minutes, so the bridge button can be pressed at any time.
    private func autoPairHue() async {
        for _ in 0..<150 {
            do {
                Keychain.set(try await hue.pair(), for: "hue.key")
                await refreshHue()
                let scenes = hueScenes.map { "\($0.id) | \($0.room) | \($0.name)" }.joined(separator: "\n")
                writeSpikeStatus("PAIRED \(hueScenes.count) scenes\n\(scenes)\n")
                return
            } catch where error.localizedDescription.contains("link button") {
                try? await Task.sleep(for: .seconds(2))
            } catch {
                writeSpikeStatus("ERROR \(error.localizedDescription)\n")
                return
            }
        }
        writeSpikeStatus("TIMEOUT\n")
    }

    private func spikeLoginSpotify() async {
        try? await Task.sleep(for: .seconds(3)) // The login sheet needs a window.
        if spotify.isLoggedIn { await refreshSpotify() } else { await loginSpotify() }
        guard spotify.isLoggedIn else {
            writeSpikeStatus("SPOTIFY_ERROR \(spotifyMessage)\n")
            return
        }
        let devices = spotifyDevices.map { "DEVICE \($0.name) | \($0.type) | active=\($0.is_active)" }
        let lists = playlists.prefix(100).map { "PLAYLIST \($0.name) | \($0.uri)" }
        writeSpikeStatus((["SPOTIFY_OK \(spotifyMessage)"] + devices + lists).joined(separator: "\n") + "\n")
    }

    private func spikePlay(uri: String, deviceName: String) async {
        await refreshSpotify()
        guard let device = spotifyDevices.first(where: { $0.name == deviceName }) else {
            writeSpikeStatus("PLAY_ERROR \(deviceName) is not visible. \(spotifyMessage)\n\(logText)\n")
            return
        }
        chooseOutput(device)
        let started = Date()
        do {
            try await spotify.play(contextURI: uri, deviceID: device.id ?? "", deviceName: device.name, shuffle: true, volume: nil)
            writeSpikeStatus("PLAYED in \(Int(Date().timeIntervalSince(started) * 1000)) ms\n\(logText)\n")
        } catch {
            writeSpikeStatus("PLAY_ERROR \(error.localizedDescription)\n\(logText)\n")
        }
    }

    private func fireHueScene(_ sceneID: String) async {
        let started = Date()
        do {
            try await hue.recall(sceneID: sceneID, dynamic: false, fadeSeconds: 2)
            writeSpikeStatus("FIRED in \(Int(Date().timeIntervalSince(started) * 1000)) ms\n")
        } catch {
            writeSpikeStatus("ERROR \(error.localizedDescription)\n")
        }
    }

    /// Light designs saved while away become real Hue scenes as soon as the bridge is reachable.
    func realizeLightDesigns() {
        guard hue.isPaired else { return }
        for preset in presets where !designsInProgress.contains(preset.id) {
            guard let design = preset.lightDesign else { continue }
            designsInProgress.insert(preset.id)
            Task {
                defer { designsInProgress.remove(preset.id) }
                do {
                    let sceneID = try await hue.createScene(design)
                    var updated = presets.first { $0.id == preset.id } ?? preset
                    updated.hueSceneID = sceneID
                    updated.lightDesign = nil
                    save(updated)
                    log("Hue", "Created scene \(design.name)")
                    await refreshHue()
                } catch {
                    log("Hue", "Design \(design.name) not created yet: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: Hue setup

    func findBridge() async {
        hueMessage = "Searching…"
        do {
            let ip = try await HueClient.discover()
            setBridgeIP(ip)
            hueMessage = "Found the bridge at \(ip)."
        } catch {
            hueMessage = error.localizedDescription
        }
    }

    func setBridgeIP(_ ip: String) {
        bridgeIP = ip
        hue.bridgeIP = ip.isEmpty ? nil : ip
        UserDefaults.standard.set(ip, forKey: "hue.ip")
    }

    func pairBridge() async {
        hueMessage = "Pairing…"
        do {
            Keychain.set(try await hue.pair(), for: "hue.key")
            hueMessage = "Paired."
            await refreshHue()
            realizeLightDesigns()
        } catch {
            hueMessage = error.localizedDescription
        }
    }

    func refreshHue() async {
        guard hue.isPaired else { return }
        do {
            hueScenes = try await hue.scenes()
            hueMessage = "\(hueScenes.count) scenes loaded."
        } catch {
            hueMessage = error.localizedDescription
        }
    }

    // MARK: Spotify setup

    func setClientID(_ id: String) {
        spotifyClientID = id
        spotify.clientID = id
        UserDefaults.standard.set(id, forKey: "spotify.client")
    }

    func loginSpotify() async {
        do {
            try await spotify.logIn()
            spotifyMessage = "Logged in."
            await refreshSpotify()
        } catch {
            spotifyMessage = error.localizedDescription
        }
    }

    func logoutSpotify() {
        spotify.logOut()
        spotifyDevices = []
        playlists = []
        spotifyMessage = "Logged out."
    }

    func refreshSpotify() async {
        guard spotify.isLoggedIn else { return }
        do {
            spotifyDevices = try await spotify.devices()
            playlists = try await spotify.playlists()
            spotifyMessage = "\(spotifyDevices.count) players, \(playlists.count) playlists."
        } catch {
            spotifyMessage = error.localizedDescription
        }
    }

    func chooseOutput(_ device: SpotifyDevice) {
        outputID = device.id ?? ""
        outputName = device.name
        UserDefaults.standard.set(outputID, forKey: "spotify.output.id")
        UserDefaults.standard.set(outputName, forKey: "spotify.output.name")
    }
}
