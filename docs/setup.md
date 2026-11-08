# Setup

## What you need

- A Mac with Xcode 27 and XcodeGen (`brew install xcodegen`).
- A Philips Hue Bridge on the same network as the iPad.
- Spotify Premium, and a Spotify app at developer.spotify.com/dashboard with Web API enabled and the redirect URI `mirage-arcane://spotify-callback`.

## First install on an iPad

1. Connect the iPad by USB and tap **Trust**.
2. Run `scripts/install.sh`. The first attempt can fail, but it makes the Developer Mode switch appear.
3. On the iPad, turn on Settings > Privacy & Security > Developer Mode, and restart.
4. Run `scripts/install.sh` again.
5. Open Settings > General > VPN & Device Management, and trust your developer profile.

## First run in the app

1. Allow Local Network access.
2. Gear icon: tap **Find bridge**, press the bridge button, and tap **Pair** within 30 seconds.
3. Paste the Spotify Client ID and log in.
4. Press play once in Spotify on the Mac, tap **Refresh players and playlists**, and choose the Mac.

## Game-night checklist

1. Run `scripts/install.sh` if the last install is close to 7 days old.
2. Connect the speaker to the Mac, open Spotify, and press play once.
3. On the iPad, open Control Center > Screen Mirroring, and choose the Apple TV.
4. Open Mirage Arcane and keep it open. The three icons at top left should be green.
