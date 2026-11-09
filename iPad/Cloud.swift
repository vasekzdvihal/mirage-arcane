import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import FirebaseStorage
import GoogleSignIn
import Observation
import UIKit

struct Campaign: Identifiable, Hashable {
    let id: String
    var name: String
    var order: Int
}

struct CampaignLocation: Identifiable, Hashable {
    let id: String
    var campaignId: String
    var name: String
    var order: Int
}

extension LightDesign {
    init?(firestore data: [String: Any]) {
        guard let name = data["name"] as? String, let groupId = data["groupId"] as? String,
              let groupType = data["groupType"] as? String, let actions = data["actions"] as? [[String: Any]] else { return nil }
        self.init(name: name, groupId: groupId, groupType: groupType, actions: actions.compactMap { item in
            guard let lightId = item["lightId"] as? String else { return nil }
            return Action(lightId: lightId, on: item["on"] as? Bool ?? true,
                          brightness: (item["brightness"] as? NSNumber)?.doubleValue,
                          x: (item["x"] as? NSNumber)?.doubleValue,
                          y: (item["y"] as? NSNumber)?.doubleValue)
        })
    }

    var firestoreData: [String: Any] {
        [
            "name": name,
            "groupId": groupId,
            "groupType": groupType,
            "actions": actions.map { action in
                var item: [String: Any] = ["lightId": action.lightId, "on": action.on]
                if let brightness = action.brightness { item["brightness"] = brightness }
                if let x = action.x, let y = action.y {
                    item["x"] = x
                    item["y"] = y
                }
                return item
            },
        ]
    }
}

extension Preset {
    init?(id: String, data: [String: Any]) {
        guard let name = data["name"] as? String else { return nil }
        self.init(id: id, name: name)
        locationId = data["locationId"] as? String
        order = data["order"] as? Int
        hueSceneID = data["hueSceneID"] as? String
        hueDynamic = data["hueDynamic"] as? Bool ?? false
        lightDesign = (data["lightDesign"] as? [String: Any]).flatMap(LightDesign.init(firestore:))
        playlistURI = data["playlistURI"] as? String
        playlistName = data["playlistName"] as? String
        shuffle = data["shuffle"] as? Bool ?? true
        volume = data["volume"] as? Int
        imageHash = data["imageHash"] as? String
        fadeSeconds = (data["fadeSeconds"] as? NSNumber)?.doubleValue ?? 2
    }

    var firestoreData: [String: Any] {
        [
            "name": name,
            "locationId": locationId ?? NSNull(),
            "order": order ?? NSNull(),
            "hueSceneID": hueSceneID ?? NSNull(),
            "hueDynamic": hueDynamic,
            "lightDesign": lightDesign?.firestoreData ?? NSNull(),
            "playlistURI": playlistURI ?? NSNull(),
            "playlistName": playlistName ?? NSNull(),
            "shuffle": shuffle,
            "volume": volume ?? NSNull(),
            "imageHash": imageHash ?? NSNull(),
            "fadeSeconds": fadeSeconds,
        ]
    }
}

/// Signs in with Google and keeps scenes in sync with Firestore and Storage.
/// Firestore's on-device cache and the local image folder keep the app usable with no connection.
@MainActor
@Observable
final class CloudStore {
    enum AuthState: Equatable {
        case unconfigured, signedOut
        case signedIn(String)
    }

    private(set) var authState = AuthState.unconfigured
    private(set) var campaigns: [Campaign] = []
    private(set) var locations: [CampaignLocation] = []
    private(set) var message = ""

    var onScenes: ([Preset]) -> Void = { _ in }
    var localPresetsForFirstUpload: () -> [Preset] = { [] }
    var log: (String) -> Void = { _ in }

    private var listeners: [ListenerRegistration] = []
    private var authHandle: AuthStateDidChangeListenerHandle?
    private var uid: String?
    private var imagesInFlight: Set<String> = []
    private var uploaded: Set<String> = []
    private var latestScenes: [Preset] = []
    private let localOwnerKey = "cloud.localOwner"

    init() {
        guard Bundle.main.url(forResource: "GoogleService-Info", withExtension: "plist") != nil else { return }
        FirebaseApp.configure()
        authState = .signedOut
        authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            MainActor.assumeIsolated { self?.authChanged(user) }
        }
    }

    private func authChanged(_ user: User?) {
        listeners.forEach { $0.remove() }
        listeners = []
        imagesInFlight = []
        uploaded = []
        latestScenes = []
        guard let user else {
            uid = nil
            campaigns = []
            locations = []
            if authState != .unconfigured { authState = .signedOut }
            return
        }
        uid = user.uid
        authState = .signedIn(user.email ?? "Signed in")
        listen(uid: user.uid)
    }

    private func root(_ uid: String) -> DocumentReference {
        Firestore.firestore().collection("users").document(uid)
    }

    private func listen(uid: String) {
        let user = root(uid)
        listeners.append(user.collection("campaigns").addSnapshotListener { [weak self] snapshot, error in
            MainActor.assumeIsolated { self?.campaignsChanged(snapshot, error) }
        })
        listeners.append(user.collection("locations").addSnapshotListener { [weak self] snapshot, error in
            MainActor.assumeIsolated { self?.locationsChanged(snapshot, error) }
        })
        listeners.append(user.collection("scenes").addSnapshotListener(includeMetadataChanges: true) { [weak self] snapshot, error in
            MainActor.assumeIsolated { self?.scenesChanged(snapshot, error) }
        })
    }

    private func campaignsChanged(_ snapshot: QuerySnapshot?, _ error: Error?) {
        guard let snapshot else { return report(error) }
        campaigns = snapshot.documents.compactMap { document in
            guard let name = document["name"] as? String else { return nil }
            return Campaign(id: document.documentID, name: name, order: document["order"] as? Int ?? 0)
        }.sorted { ($0.order, $0.name) < ($1.order, $1.name) }
    }

    private func locationsChanged(_ snapshot: QuerySnapshot?, _ error: Error?) {
        guard let snapshot else { return report(error) }
        locations = snapshot.documents.compactMap { document in
            guard let name = document["name"] as? String, let campaignId = document["campaignId"] as? String else { return nil }
            return CampaignLocation(id: document.documentID, campaignId: campaignId, name: name, order: document["order"] as? Int ?? 0)
        }.sorted { ($0.order, $0.name) < ($1.order, $1.name) }
    }

    private func scenesChanged(_ snapshot: QuerySnapshot?, _ error: Error?) {
        guard let snapshot, let uid else { return report(error) }
        // An empty answer from the cache says nothing about the server.
        if snapshot.documents.isEmpty {
            if !snapshot.metadata.isFromCache, !firstUploadIfNeeded(uid: uid) {
                latestScenes = []
                onScenes([]) // The account really has no scenes, so show none.
            }
            return
        }
        let scenes = snapshot.documents
            .compactMap { Preset(id: $0.documentID, data: $0.data()) }
            .sorted { ($0.order ?? Int.max, $0.name) < ($1.order ?? Int.max, $1.name) }
        latestScenes = scenes
        UserDefaults.standard.set(uid, forKey: localOwnerKey) // Local scenes now belong to this account.
        onScenes(scenes)
        downloadMissingImages(scenes, uid: uid)
    }

    private func report(_ error: Error?) {
        guard let error else { return }
        message = error.localizedDescription
        log("Error: \(error.localizedDescription)")
    }

    // MARK: Writing

    func save(_ preset: Preset) {
        guard let uid else { return }
        root(uid).collection("scenes").document(preset.id).setData(preset.firestoreData)
        upload(preset, uid: uid)
    }

    func delete(_ preset: Preset) {
        guard let uid else { return }
        root(uid).collection("scenes").document(preset.id).delete()
    }

    /// Moves the scenes made before login into the account, once per account.
    /// Returns true when local scenes were sent to the account.
    private func firstUploadIfNeeded(uid: String) -> Bool {
        let key = "cloud.firstUpload.\(uid)"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: key) else { return false }
        // Scenes synced from one account must never be uploaded into another.
        if let owner = defaults.string(forKey: localOwnerKey), owner != uid { return false }
        defaults.set(true, forKey: key)
        defaults.set(uid, forKey: localOwnerKey)
        let presets = localPresetsForFirstUpload()
        guard !presets.isEmpty else { return false }

        let user = root(uid)
        let campaign = user.collection("campaigns").document()
        let location = user.collection("locations").document()
        let batch = Firestore.firestore().batch()
        batch.setData(["name": "My Campaign", "order": 0], forDocument: campaign)
        batch.setData(["campaignId": campaign.documentID, "name": "Scenes", "order": 0], forDocument: location)
        for (index, var preset) in presets.enumerated() {
            preset.locationId = location.documentID
            preset.order = index
            batch.setData(preset.firestoreData, forDocument: user.collection("scenes").document(preset.id))
            upload(preset, uid: uid)
        }
        batch.commit { [weak self] error in
            MainActor.assumeIsolated {
                if let error { self?.report(error) } else { self?.log("Uploaded \(presets.count) local scenes") }
            }
        }
        return true
    }

    // MARK: Images

    private func imageReference(_ hash: String, uid: String) -> StorageReference {
        Storage.storage().reference(withPath: "users/\(uid)/images/\(hash).jpg")
    }

    private func upload(_ preset: Preset, uid: String) {
        guard let hash = preset.imageHash, !uploaded.contains(hash), let data = Store.imageData(hash) else { return }
        uploaded.insert(hash)
        let metadata = StorageMetadata()
        metadata.contentType = "image/jpeg"
        Task {
            do {
                _ = try await imageReference(hash, uid: uid).putDataAsync(data, metadata: metadata)
                log("Uploaded image \(hash.prefix(8))")
            } catch {
                uploaded.remove(hash)
                report(error)
            }
        }
    }

    private func downloadMissingImages(_ scenes: [Preset], uid: String) {
        for hash in Set(scenes.compactMap(\.imageHash)) where Store.imageData(hash) == nil && !imagesInFlight.contains(hash) {
            imagesInFlight.insert(hash)
            Task {
                defer { imagesInFlight.remove(hash) }
                do {
                    let data = try await imageReference(hash, uid: uid).data(maxSize: 30 * 1024 * 1024)
                    guard self.uid == uid else { return } // The account changed during the download.
                    guard Link.hash(of: data) == hash else { return log("Image \(hash.prefix(8)) failed its checksum") }
                    Store.write(data, hash: hash)
                    onScenes(latestScenes) // Redraw the tiles with the new image.
                } catch {
                    report(error)
                }
            }
        }
    }

    // MARK: Sign-in

    func signIn() async {
        guard let clientID = FirebaseApp.app()?.options.clientID else {
            message = "Google sign-in is not enabled for this Firebase project."
            return
        }
        guard var presenter = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow?.rootViewController }).first else { return }
        while let next = presenter.presentedViewController { presenter = next }

        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
            guard let idToken = result.user.idToken?.tokenString else { throw AppError("Google returned no identity token.") }
            let credential = GoogleAuthProvider.credential(withIDToken: idToken, accessToken: result.user.accessToken.tokenString)
            _ = try await Auth.auth().signIn(with: credential)
            message = ""
        } catch {
            message = error.localizedDescription
        }
    }

    func signOut() {
        GIDSignIn.sharedInstance.signOut()
        try? Auth.auth().signOut()
    }
}
