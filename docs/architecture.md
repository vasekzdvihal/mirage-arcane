# Architecture

The iPad app is the only required app on the devices. The scene library syncs through Firebase, see `backend.md`. Everything below works from the iPad's local copy, so firing a scene needs no database.

```
                   ┌── HTTPS, local network ──▶ Hue Bridge ──▶ lights
iPad app ── tap ───┼── HTTPS, internet ───────▶ Spotify Web API ──▶ Spotify on the Mac ──▶ speaker
                   └── AirPlay mirroring ─────▶ Apple TV ──HDMI──▶ projector
```

## Firing a scene

`AppModel.fire(preset)` starts one independent task per system. Each tile shows one status icon per system: yellow while working, green on success, red on failure. The Log screen shows every step with timing.

| Preset field | Used by |
|---|---|
| `hueSceneID`, `hueDynamic` | Hue recall |
| `playlistURI`, `shuffle`, `volume` | Spotify |
| `imageHash` | Projector |
| `fadeSeconds` | Hue transition and image crossfade |

Scenes are cached in `Documents/presets.json`. Images are JPEGs, at most 4K, stored in `Documents/images/` and named by SHA-256.

## Hue (`iPad/HueClient.swift`)

- CLIP API v2 on the bridge, over HTTPS.
- Discovery uses Bonjour `_hue._tcp`. The host name comes from the TXT record `bridgeid`: drop the middle `fffe` and add `.local`.
- Pairing: `POST /api` after the bridge button is pressed. The key is stored in the Keychain.
- Firing: `PUT /clip/v2/resource/scene/{id}` with `recall.action` set to `active`, or `dynamic_palette` for animated scenes.
- Scenes come from the official Hue app or from the MCP server. The app selects them, and creates one from a saved `lightDesign` when the bridge is in reach.

## Spotify (`iPad/SpotifyClient.swift`)

- Web API in Development Mode, with OAuth PKCE. The app holds no client secret.
- Redirect URI: `mirage-arcane://spotify-callback`. The refresh token is stored in the Keychain.
- Output is any visible Spotify Connect player, chosen in Setup. The default is the Mac desktop app.
- The player id is saved with its name. If the id changes, the app matches on the name.
- Firing order: list devices, transfer if not active, volume, play, wait 400 ms, shuffle, next.

## Projector (`iPad/ExternalDisplay.swift`)

- The user starts Screen Mirroring to the Apple TV. An app cannot start it.
- The app then receives an external scene and shows `ExternalStageView`, which replaces the mirrored picture.
- Crossfade: a new image layer fades in over the old one, and the old layer is removed afterwards.
- The app must stay open on the iPad. It disables the idle timer so the iPad does not lock.

## Apple TV fallback (`TV/`, `Shared/Link.swift`)

Used only when no second screen is connected. The TV app advertises `_mirage-arcane._tcp`, and the iPad connects over TCP with length-prefixed frames.

1. The iPad sends `show(hash)`.
2. If the TV has the file, it displays it and replies `shown`.
3. If not, it replies `need`, the iPad sends `put` with the bytes, and the TV stores, displays and replies `shown`.

This also recovers when tvOS purges its cache.

## Test hooks

`AppModel.init` reads launch arguments so an agent can drive the app without touching the screen. Results go to `Documents/spike-status.txt`.

| Argument | Effect |
|---|---|
| `-pairHue` | Finds the bridge, retries pairing for 5 minutes |
| `-fireHueScene <id>` | Fires one Hue scene |
| `-spotifyClient <id>` | Saves the Spotify Client ID |
| `-loginSpotify` | Opens login, then lists players and playlists |
| `-playSpotify <uri> <device>` | Plays a playlist on a named player |
| `-fireFirstPreset` | Fires the first preset after 4 seconds |

On a real device, pass arguments after `--`:

```bash
xcrun devicectl device process launch --device <udid> --terminate-existing \
  cz.zdvihal.miragearcane.ipad -- -pairHue
```
