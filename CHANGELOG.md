# Changelog

## [Unreleased]

### Added

- One-tap scenes on a native iPad app: a Hue scene, a Spotify playlist, and a full-screen image on the projector through AirPlay.
- Per-system status on each scene tile, and a log with timing. One failing system never blocks the others.
- Google login and a cloud library of campaigns, locations, scenes and images in Firebase, with live sync and a local copy on the iPad.
- Automatic upload of existing local scenes on first login.
- MCP server that lets an agent build the library and attach images.
- Hue tools for agents: list rooms, lights and scenes, create scenes from colors, preview and delete them.
- Light designs saved while away from home, which the iPad creates on the bridge when it is back in reach.
- Fallback Apple TV app, and `scripts/install.sh` for the 7-day reinstall.

### Security

- Security rules give each user access only to their own data, covered by emulator tests.
- The MCP checks the bridge certificate against the Hue root CA and the paired bridge id.
- Firebase config, tokens and bridge keys stay out of this public repo.
