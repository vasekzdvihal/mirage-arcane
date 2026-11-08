# Roadmap

## Done: proof of concept (2026-11-08)

Working on the real iPad (8th generation, iPadOS 26.7): one tap changes the Hue scene, starts a Spotify playlist on the Mac, and shows an image on the projector through AirPlay.

## Not tested yet

- Spotify after a long idle period, such as 30 minutes with the Mac player paused.
- AirPlay stability over a full session.

## Next

1. **Login and cloud database.** Presets and images move from the iPad to a backend, so they can be filled from outside the app. Firebase is the candidate. Design not agreed yet.
2. **MCP server for the app's data.** An agent can create and edit campaigns, locations and presets.
3. **Hue and Spotify MCP servers** (separate work) let an agent find scene IDs and playlists to put into presets.

## Later

- Organise presets as Campaign, Location, Preset.
- Pre-session check screen for all systems.
- Looping video, volume fades, sound effects.
- Pin the Hue root CA and check the bridge ID against the certificate. Remove the test hooks or put them behind a debug flag.
- If the Apple TV fallback is ever used for real, add pairing and encryption to its network link. Today any device on the network can connect to it.
