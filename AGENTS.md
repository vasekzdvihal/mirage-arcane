# AGENTS.md
Native iPad app (SwiftUI, Swift 5 mode, iOS 17+) that fires a tabletop RPG scene with one tap: Hue lights, Spotify playlist, and an image on the projector. Personal use, never on the App Store.

## Commands (run from repo root)
```bash
xcodegen generate       # after any project.yml change or new source file
scripts/install.sh      # rebuild and reinstall on the real iPad (free signing lasts 7 days)
xcodebuild -quiet -project MirageArcane.xcodeproj -scheme MirageIPad \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build build
PATH="$PWD/mcp/node_modules/.bin:$PATH" pnpm --dir mcp test   # MCP and security rules, on the Firebase emulator
```

## Architecture
- The Xcode project and both `Info.plist` files are generated. Edit `project.yml`, never the generated files.
- Each system fires independently in `AppModel.fire`. One failure must never block the other two.
- The projector path is AirPlay Screen Mirroring from the iPad (`iPad/ExternalDisplay.swift`). The `TV/` app is only a fallback.
- Keep the music code behind one module (`SpotifyClient`). Spotify's API rules change often.
- The scene library lives in Firebase. Hue keys and Spotify tokens stay on their device and must never reach Firestore.
- Agents change the library and the bridge only through the MCP server in `mcp/`. Bridge pairing stays a command, never an MCP tool.

## Gotchas
- Connect to the Hue Bridge by its `.local` name, not its IP. App Transport Security rejects the bridge certificate on a public-range IP, and some home networks use one (error -9802).
- Spotify returns 403 for shuffle until a context is playing. Keep the order: play, shuffle, next.
- Second screen needs two registrations: a `UISceneAccessory` on iPadOS 27+, and the scene manifest plus `AppDelegate` on iPadOS 26 and older. The real iPad runs 26.
- Xcode 27 has no Simulator app. Use `DeviceHub.app` in `Xcode.app/Contents/Applications`.
- With a simulated second screen, power it on with `simctl io <id> screenConfig --display=external power on`, then relaunch the app.
- `iPad/GoogleService-Info.plist` and `iPad/Firebase.local.xcconfig` are gitignored. A new checkout or worktree needs them copied or `scripts/firebase-config.sh`, or the app builds with cloud features off.
- `pnpm` here is a zsh alias for corepack, so bash scripts need the corepack shims on `PATH`.
- `pnpm --dir mcp test` needs ports 9099, 8085 and 9199. Other projects' emulators can hold them. Do not kill those; use a temporary config with other ports.
- After changing `mcp/src`, run `pnpm --dir mcp build`. Claude Code runs `mcp/dist/index.js` from the main checkout, and new tools load only in a new session.
- Sign only with the Personal Team in `project.yml`. Never switch to the company teams that this Mac is also signed in to.
- The app accepts any certificate from the bridge (`BridgeTrust`). Pin the Hue root CA before this leaves POC.

## Workflow
1. Branch from `main` for each change.
2. Verify on a simulator matching iPadOS 26 and 27 when touching the second screen.
3. Never commit tokens or Firebase config. This repo is public. The Spotify Client ID and Hue key are entered at runtime.

## Map
- docs/architecture.md — how the app talks to Hue, Spotify and the projector, plus test hooks
- docs/backend.md — Firebase data model, security rules, MCP server, project setup
- docs/setup.md — first-time setup on a new device, accounts, game-night checklist
- docs/roadmap.md — what is done and what comes next
- docs/analysis.md — original feasibility analysis, dated record with sources
