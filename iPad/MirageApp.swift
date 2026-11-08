import GoogleSignIn
import PhotosUI
import SwiftUI

@main
struct MirageIPadApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            StageView()
                .background(ExternalDisplayRegistrar().frame(width: 0, height: 0))
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(Color(red: 0.86, green: 0.68, blue: 0.36))
                .statusBarHidden(true)
                .onOpenURL { GIDSignIn.sharedInstance.handle($0) }
                .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        }
    }
}

private enum ActiveSheet: Identifiable {
    case setup, log, edit(Preset)
    var id: String {
        switch self {
        case .setup: "setup"
        case .log: "log"
        case .edit(let preset): preset.id
        }
    }
}

struct StageView: View {
    @Environment(AppModel.self) private var model
    @State private var sheet: ActiveSheet?

    private let columns = [GridItem(.adaptive(minimum: 300), spacing: 20)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    ForEach(Array(model.sections.enumerated()), id: \.offset) { _, section in
                        VStack(alignment: .leading, spacing: 12) {
                            if let title = section.title {
                                Text(title)
                                    .font(.system(.title3, design: .serif).weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            LazyVGrid(columns: columns, spacing: 20) {
                                ForEach(section.presets) { preset in
                                    Button { model.fire(preset) } label: { PresetTile(preset: preset) }
                                        .buttonStyle(.plain)
                                        .contextMenu {
                                            Button("Edit", systemImage: "pencil") { sheet = .edit(preset) }
                                            Button("Delete", systemImage: "trash", role: .destructive) { model.delete(preset) }
                                        }
                                }
                            }
                        }
                    }
                }
                .padding(24)
            }
            .background(Color(red: 0.06, green: 0.05, blue: 0.08))
            .navigationTitle("Mirage Arcane")
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    ConnectionPill(symbol: "lightbulb.fill", isOn: model.huePaired)
                    ConnectionPill(symbol: "music.note", isOn: model.spotifyLoggedIn && !model.outputName.isEmpty)
                    ConnectionPill(symbol: "tv.fill", isOn: model.tv.isConnected || ExternalStage.shared.isConnected)
                }
                ToolbarItem(placement: .principal) {
                    if model.cloud.campaigns.count > 1 {
                        Picker("Campaign", selection: Binding(
                            get: { model.selectedCampaign?.id },
                            set: { model.selectedCampaignID = $0 })) {
                            ForEach(model.cloud.campaigns) { Text($0.name).tag(String?.some($0.id)) }
                        }
                        .pickerStyle(.menu)
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Log", systemImage: "list.bullet.rectangle") { sheet = .log }
                    Button("Setup", systemImage: "gearshape") { sheet = .setup }
                    Button("Add", systemImage: "plus") { sheet = .edit(Preset(name: "New scene")) }
                }
            }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .setup: SetupView()
            case .log: LogView()
            case .edit(let preset): PresetEditor(preset: preset)
            }
        }
    }
}

private struct ConnectionPill: View {
    let symbol: String
    let isOn: Bool
    var body: some View {
        Image(systemName: symbol)
            .font(.footnote)
            .foregroundStyle(isOn ? Color.green : Color.red.opacity(0.85))
    }
}

struct PresetTile: View {
    @Environment(AppModel.self) private var model
    let preset: Preset

    var body: some View {
        let isActive = model.activePresetID == preset.id
        ZStack(alignment: .bottomLeading) {
            Color.black
                .overlay {
                    if let hash = preset.imageHash, let image = Store.image(hash) {
                        Image(uiImage: image).resizable().scaledToFill()
                    }
                }
                .clipped()
            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
            HStack(alignment: .lastTextBaseline) {
                Text(preset.name)
                    .font(.system(.title3, design: .serif).weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Spacer(minLength: 12)
                HStack(spacing: 10) {
                    ForEach(Channel.allCases) { channel in
                        StatusIcon(channel: channel, status: model.statuses[preset.id]?[channel] ?? .idle)
                    }
                }
            }
            .padding(16)
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(isActive ? Color.accentColor : Color.white.opacity(0.08), lineWidth: isActive ? 3 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityLabel(preset.name)
    }
}

private struct StatusIcon: View {
    let channel: Channel
    let status: ChannelStatus

    private var color: Color {
        switch status {
        case .idle, .skipped: .white.opacity(0.35)
        case .working: .yellow
        case .ok: .green
        case .failed: .red
        }
    }

    var body: some View {
        Image(systemName: channel.symbol)
            .font(.footnote)
            .foregroundStyle(color)
            .symbolEffect(.pulse, isActive: status == .working)
    }
}

struct LogView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(model.logText.isEmpty ? "Nothing yet. Tap a scene." : model.logText)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding()
            }
            .navigationTitle("Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { ShareLink(item: model.logText) }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }
}

struct SetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    switch model.cloud.authState {
                    case .unconfigured:
                        Text("Firebase is not configured in this build.").foregroundStyle(.secondary)
                    case .signedOut:
                        Button("Sign in with Google") { Task { await model.cloud.signIn() } }
                    case .signedIn(let email):
                        Text(email)
                        Button("Sign out", role: .destructive) { model.cloud.signOut() }
                    }
                    if !model.cloud.message.isEmpty { Text(model.cloud.message).foregroundStyle(.secondary) }
                }

                Section("Hue Bridge") {
                    TextField("Bridge address", text: Binding(get: { model.bridgeIP }, set: { model.setBridgeIP($0) }))
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                    Button("Find bridge on the network") { Task { await model.findBridge() } }
                    Button(model.huePaired ? "Pair again (press the bridge button first)" : "Pair (press the bridge button first)") {
                        Task { await model.pairBridge() }
                    }
                    if !model.hueMessage.isEmpty { Text(model.hueMessage).foregroundStyle(.secondary) }
                }

                Section {
                    TextField("Client ID", text: Binding(get: { model.spotifyClientID }, set: { model.setClientID($0.trimmingCharacters(in: .whitespaces)) }))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if model.spotifyLoggedIn {
                        Button("Log out", role: .destructive) { model.logoutSpotify() }
                    } else {
                        Button("Log in to Spotify") { Task { await model.loginSpotify() } }
                    }
                    Button("Refresh players and playlists") { Task { await model.refreshSpotify() } }
                    if !model.spotifyMessage.isEmpty { Text(model.spotifyMessage).foregroundStyle(.secondary) }
                } header: {
                    Text("Spotify")
                } footer: {
                    Text("Redirect URI to register in the Spotify dashboard: \(SpotifyClient.redirectURI)")
                }

                Section("Music output") {
                    if model.spotifyDevices.isEmpty {
                        Text("No players visible. Open Spotify on your computer and press play once, then refresh.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.spotifyDevices) { device in
                        Button { model.chooseOutput(device) } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(device.name).foregroundStyle(.primary)
                                    Text(device.type + (device.is_active ? ", active" : "")).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if device.name == model.outputName { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }

                Section("Projector") {
                    if ExternalStage.shared.isConnected {
                        Label("Second screen connected", systemImage: "checkmark.circle.fill")
                    } else if model.tv.isConnected {
                        Label("Apple TV app connected", systemImage: "checkmark.circle.fill")
                    } else {
                        Label("Not connected. Open Control Center, tap Screen Mirroring, and choose your Apple TV.",
                              systemImage: "airplayvideo")
                    }
                }
            }
            .navigationTitle("Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}

struct PresetEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var preset: Preset
    @State private var photo: PhotosPickerItem?

    var body: some View {
        NavigationStack {
            Form {
                Section("Scene") {
                    TextField("Name", text: $preset.name)
                    VStack(alignment: .leading) {
                        Text("Transition: \(preset.fadeSeconds, specifier: "%.1f") s")
                        Slider(value: $preset.fadeSeconds, in: 0...10, step: 0.5)
                    }
                }

                if !model.cloud.locations.isEmpty {
                    Section("Location") {
                        Picker("Location", selection: $preset.locationId) {
                            Text("Unsorted").tag(String?.none)
                            ForEach(model.cloud.locations) { Text($0.name).tag(String?.some($0.id)) }
                        }
                    }
                }

                Section("Lights") {
                    Picker("Hue scene", selection: $preset.hueSceneID) {
                        Text("None").tag(String?.none)
                        ForEach(model.hueScenes) { scene in
                            Text("\(scene.room) · \(scene.name)").tag(String?.some(scene.id))
                        }
                    }
                    Toggle("Animated (dynamic scene)", isOn: $preset.hueDynamic)
                }

                Section("Music") {
                    Picker("Playlist", selection: $preset.playlistURI) {
                        Text("None").tag(String?.none)
                        ForEach(model.playlists) { playlist in
                            Text(playlist.name).tag(String?.some(playlist.uri))
                        }
                    }
                    Toggle("Shuffle", isOn: $preset.shuffle)
                    Toggle("Set volume", isOn: Binding(
                        get: { preset.volume != nil },
                        set: { preset.volume = $0 ? 50 : nil }))
                    if preset.volume != nil {
                        Slider(value: Binding(
                            get: { Double(preset.volume ?? 50) },
                            set: { preset.volume = Int($0) }), in: 0...100, step: 5)
                    }
                }

                Section("Projector image") {
                    if let hash = preset.imageHash, let image = Store.image(hash) {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 220)
                    }
                    PhotosPicker("Choose image", selection: $photo, matching: .images)
                }
            }
            .navigationTitle(preset.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        model.save(preset)
                        dismiss()
                    }
                }
            }
            .onChange(of: photo) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                        preset.imageHash = Store.importImage(image)
                    }
                }
            }
        }
    }
}
