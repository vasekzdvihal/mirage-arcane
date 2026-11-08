import Network
import Observation
import SwiftUI

@main
struct MirageTVApp: App {
    var body: some Scene {
        WindowGroup { TVRoot() }
    }
}

struct ShownImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

@MainActor
@Observable
final class TVServer {
    var layers: [ShownImage] = []
    var status = "Starting…"
    var connected = false

    private var listener: NWListener?
    private var channel: FrameChannel?
    private var latestHash: String?
    private var pendingFade: Double = 1.5

    private let cacheDirectory: URL = {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("mirage", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    func start() {
        guard listener == nil else { return }
        do {
            let listener = try NWListener(using: Link.parameters())
            listener.service = NWListener.Service(name: Link.serviceName, type: Link.serviceType)
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.listenerChanged(state) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            status = "Listener failed: \(error.localizedDescription)"
        }
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready: if !connected { status = "Waiting for the iPad…" }
        case .failed(let error):
            status = "Network error: \(error.localizedDescription)"
            listener?.cancel()
            listener = nil
            Task {
                try? await Task.sleep(for: .seconds(2))
                start()
            }
        default: break
        }
    }

    private func accept(_ connection: NWConnection) {
        channel?.cancel()
        let channel = FrameChannel(connection)
        self.channel = channel
        channel.onState = { [weak self, weak channel] state in
            MainActor.assumeIsolated {
                guard let self, self.channel === channel else { return }
                switch state {
                case .ready:
                    self.connected = true
                    self.status = "iPad connected"
                case .failed, .cancelled:
                    self.connected = false
                    self.status = "Waiting for the iPad…"
                default: break
                }
            }
        }
        channel.onMessage = { [weak self] message, payload in
            MainActor.assumeIsolated { self?.handle(message, payload) }
        }
        channel.start()
    }

    private func file(_ hash: String) -> URL {
        cacheDirectory.appendingPathComponent(hash).appendingPathExtension("jpg")
    }

    private func handle(_ message: LinkMessage, _ payload: Data) {
        guard Link.isValidHash(message.hash) else { return }
        switch message.kind {
        case .show:
            latestHash = message.hash
            pendingFade = min(max(message.fade ?? 1.5, 0), 10)
            if let data = try? Data(contentsOf: file(message.hash)) {
                present(data, hash: message.hash)
            } else {
                channel?.send(LinkMessage(kind: .need, hash: message.hash))
            }
        case .put:
            guard Link.hash(of: payload) == message.hash else { return }
            try? payload.write(to: file(message.hash), options: .atomic)
            present(payload, hash: message.hash)
        case .need, .shown:
            break
        }
    }

    private func present(_ data: Data, hash: String) {
        Task {
            // Decode before the fade starts, so the animation does not stutter.
            guard let prepared = await UIImage(data: data)?.byPreparingForDisplay() else { return }
            guard hash == latestHash else { return } // A newer scene arrived while decoding.
            let fade = pendingFade
            withAnimation(.easeInOut(duration: fade)) {
                layers.append(ShownImage(image: prepared))
            }
            channel?.send(LinkMessage(kind: .shown, hash: hash))
            try? await Task.sleep(for: .seconds(fade + 0.1))
            if layers.count > 1 { layers.removeFirst(layers.count - 1) }
        }
    }
}

struct TVRoot: View {
    @State private var server = TVServer()

    var body: some View {
        ZStack {
            Color.black
            ForEach(server.layers) { layer in
                GeometryReader { geometry in
                    Image(uiImage: layer.image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                }
                .transition(.asymmetric(insertion: .opacity, removal: .identity))
            }
            if server.layers.isEmpty {
                VStack(spacing: 24) {
                    Text("Mirage Arcane").font(.system(size: 76, weight: .semibold, design: .serif))
                    Text(server.status).font(.title3).foregroundStyle(.secondary)
                }
                .foregroundStyle(.white)
            }
        }
        .ignoresSafeArea()
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            server.start()
        }
    }
}
