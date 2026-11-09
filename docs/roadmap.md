# Roadmap

## Done: proof of concept (2026-11-08)

Working on the real iPad (8th generation, iPadOS 26.7): one tap changes the Hue scene, starts a Spotify playlist on the Mac, and shows an image on the projector through AirPlay.

## Not tested yet

- Spotify after a long idle period, such as 30 minutes with the Mac player paused.
- AirPlay stability over a full session.
- The iPad turning a saved light design into a real Hue scene.

## Done: cloud library and agent tools

Google login, Firebase sync, and an MCP server that builds the library and designs Hue scenes. See `backend.md`.

## Next

1. **Spotify access for agents.** Best candidate is `marcelmarais/spotify-mcp-server`. It needs Node 26.8.1 or newer, the Spotify Client Secret, and one more redirect URI. Until then, playlist URIs come from the app.
2. **Real content.** Replace placeholder images and build the campaign scenes.
3. **Pre-session check screen** for all systems.

## Later

- Looping video, volume fades, sound effects.
- Pin the Hue root CA and check the bridge ID against the certificate. Remove the test hooks or put them behind a debug flag.
- If the Apple TV fallback is ever used for real, add pairing and encryption to its network link, and limit image and cache size. Today any device on the network can connect to it.
