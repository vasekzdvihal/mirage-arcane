import Observation
import SwiftUI

struct StageLayer: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// The image shown on a second screen (AirPlay to the Apple TV, or a cable).
@MainActor
@Observable
final class ExternalStage {
    static let shared = ExternalStage()

    var isConnected = false
    var layers: [StageLayer] = []

    func show(hash: String, fade: Double) async throws {
        guard let data = Store.imageData(hash),
              let prepared = await UIImage(data: data)?.byPreparingForDisplay() else {
            throw AppError("Could not read the image.")
        }
        withAnimation(.easeInOut(duration: fade)) {
            layers.append(StageLayer(image: prepared))
        }
        Task {
            try? await Task.sleep(for: .seconds(fade + 0.1))
            if layers.count > 1 { layers.removeFirst(layers.count - 1) }
        }
    }
}

struct ExternalStageView: View {
    private let stage = ExternalStage.shared

    var body: some View {
        ZStack {
            Color.black
            ForEach(stage.layers) { layer in
                GeometryReader { geometry in
                    Image(uiImage: layer.image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                }
                .transition(.asymmetric(insertion: .opacity, removal: .identity))
            }
            if stage.layers.isEmpty {
                Text("Mirage Arcane")
                    .font(.system(size: 64, weight: .semibold, design: .serif))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .ignoresSafeArea()
    }
}

final class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        // Apple requires the mode to be set before a window is attached.
        let screen = windowScene.screen
        if let preferred = screen.preferredMode { screen.currentMode = preferred }
        let window = UIWindow(windowScene: windowScene)
        window.frame = screen.bounds
        window.rootViewController = UIHostingController(rootView: ExternalStageView())
        window.makeKeyAndVisible()
        self.window = window
        MainActor.assumeIsolated { ExternalStage.shared.isConnected = true }
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        window = nil
        MainActor.assumeIsolated { ExternalStage.shared.isConnected = false }
    }
}

/// iPadOS 26 and older offer the external scene through the app delegate.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        if session.role == .windowExternalDisplayNonInteractive {
            configuration.delegateClass = ExternalDisplaySceneDelegate.self
        }
        return configuration
    }
}

/// iPadOS 27 and newer give the external scene only to a registered scene accessory.
struct ExternalDisplayRegistrar: UIViewControllerRepresentable {
    final class Controller: UIViewController {
        private var registration: AnyObject?

        override func viewDidLoad() {
            super.viewDidLoad()
            view.isHidden = true
            if #available(iOS 27, *) {
                let configuration = UISceneConfiguration()
                configuration.delegateClass = ExternalDisplaySceneDelegate.self
                registration = registerSceneAccessory(UISceneAccessory.externalNonInteractive(sceneConfiguration: configuration))
            }
        }
    }

    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {}
}
