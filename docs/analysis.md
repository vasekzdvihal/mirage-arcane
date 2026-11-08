# Mirage Arcane: feasibility analysis

Date: 2026-11-08. Goal: one tap on an iPad changes the Hue lights, the Spotify music and the projected image.

> Dated record. The POC later chose AirPlay mirroring (option B) over the Apple TV app. See `architecture.md` for what is built.

## Result

The app is possible as a native app. It is two small apps in one Xcode project:

- **iPad app:** you create and fire the presets here.
- **Apple TV app:** it shows the image on the projector. The iPad tells it what to show.

| Part | Feasibility | How | Main risk |
|---|---|---|---|
| Hue lights | Easy | Local bridge API (you have a Hue Bridge) | Low |
| Projected image | Easy to medium | Own Apple TV app | Apple signing, cache purge on Apple TV |
| Spotify music | Medium | Spotify Web API | Speaker can be "asleep" and invisible to the API |

**Spotify is the only part that can fail in a way we cannot fully fix.** Test it first, on your real speaker.

How sure each statement is:

- **[docs]** I read it today in the vendor's documentation.
- **[reports]** It comes from forum posts or third-party sources.
- **[memory]** It is my prior knowledge. I did not confirm it today.

## 1. Hue lights

Use the local CLIP API v2 on the Hue Bridge. The iPad talks directly to the bridge. No cloud is needed. [reports]

Setup, one time only:

1. Find the bridge on the network.
2. You press the physical button on the bridge.
3. The app receives an application key and stores it in the Keychain.

To fire a scene: `PUT /clip/v2/resource/scene/{id}` with `recall.action = active`. [reports]

**Recommendation: use scenes that you create in the official Hue app.** Our app lists them, and a preset points at one.

- The bridge changes all lights together, so there is no visible ripple.
- We avoid the rate limit. Unofficial figures are about 10 commands per second per light, and 1 per second per room. [reports]
- Dynamic scenes, such as a slow flicker, work with no extra code. [memory]
- We do not need to build a colour editor. We can add one later.

Technical notes:

- The bridge uses a certificate signed by the Hue root CA. The app must handle this and pin it. [reports]
- **Tested on 2026-11-08:** the iPad simulator paired with the real bridge and fired a scene in 319 ms, and the lights changed.
- The app must connect through the bridge's `.local` name, not its IP. Your network uses public-range addresses, and Apple's App Transport Security refuses the bridge certificate on an IP in a public range (error -9802).
- iPadOS asks for Local Network permission the first time. [memory]
- Lightning-style effects need the Entertainment API (fast UDP stream). This is a later feature, not v1. [reports]

## 2. Image on the projector

The chain is iPad → Apple TV → Samsung projector. The projector only shows the HDMI signal, so we do not need to talk to it.

| Option | Good | Bad | Verdict |
|---|---|---|---|
| **A. Own Apple TV app** | Survives iPad lock and app switch. Crossfades. Video loops are possible. | Second app to install and sign | **Recommended** |
| B. iPad as AirPlay second screen | One app only | You start AirPlay by hand. It depends on the iPad screen staying in our app. | Backup |
| C. Control the Apple TV Photos app | Nothing to install | No public API [memory] | Rejected |
| D. Control the Samsung directly | No Apple TV needed | Bypasses your setup, and adds a new platform | Rejected |

**Option A in detail.** The Apple TV app announces itself on the network with Bonjour. The iPad finds it and keeps a connection open with `Network.framework`. The iPad sends "show image X, crossfade 2 s".

Three limits:

- **Storage.** tvOS gives apps only cache storage, and the system can purge it. [memory] So the iPad keeps the originals. On connect, it sends any image that the Apple TV is missing.
- **Waking.** The iPad cannot start the Apple TV app. [memory] You open it before the session. The app then keeps the screen awake.
- **Signing.** See section 4.

**Option B in detail.** iPadOS 27 requires a `UISceneAccessory` registration for this. Our view must stay on screen, and the display must be available. [docs] I found no way for an app to start AirPlay by itself.

## 3. Spotify music

### What is confirmed

- `PUT /me/player/play` accepts a playlist through `context_uri` and a target through `device_id`. [docs]
- Play, transfer, device list, volume and shuffle are all still available in Development Mode after the February 2026 lockdown. [docs]
- The app needs Spotify Premium, and scope `user-modify-playback-state`. [docs]
- `GET /me/playlists` remains, so the app can show a playlist picker. [docs]
- Track lists are only returned for playlists that you own or collaborate on. [docs] We do not need track lists to start a playlist. Confirm in the spike that other people's playlists also play.
- Your own private app can stay in Development Mode. The test-user cap is reported as 5. [reports]

### The main problem

The Web API only commands a player that Spotify can see. Developers report that a speaker can be missing from the device list until someone starts playback on it by hand. They also report 202 responses with no result, and 404 "No active device found". [reports] Retries help, but not always. I found no official method to wake a device.

### Decision: the speaker hangs on a computer or on the iPad

You can connect the speaker to a computer with Spotify, or to the iPad. Both are the same case for our app. Each one is a Spotify player with a `device_id`, and the Web API commands it from the iPad.

The app has one "music output" setting. It lists the players from `GET /me/player/devices`, and you pick one. So we do not need the Spotify iOS SDK in the first version.

| Player | Good | Bad | Verdict |
|---|---|---|---|
| **Spotify desktop app on the computer** | Desktop apps are not suspended, so the player should stay visible for the whole session. [memory] The iPad stays free. | The computer must be on, with Spotify open. | **Default** |
| Spotify app on the iPad | No extra device | iPadOS can suspend a paused Spotify app, and the player then disappears. [memory] The iPad carries all the work, and its sounds can go to the speaker. | Backup |
| Spotify app on the Apple TV | No extra device | Conflict: our image app must be on screen at the same time. [memory] | Avoid |

If the selected player is not visible, the check screen says: "Open Spotify on this device and press play once."

The spike must confirm that the desktop player stays visible while it is idle or paused.

### Other Spotify limits

- It needs internet, because commands go through Spotify's cloud.
- Player calls have no guaranteed order. [docs] The app must wait for "shuffle" to finish before it sends "play".
- A music crossfade is not available. We can approximate it with volume steps, on devices that support volume control.
- **Policy.** Spotify's page says the platform cannot be used for "synchronizing sound recordings with visual media". Starting a playlist as an image changes may fall under this if read literally. In my judgement the risk is low for a private app at your own table. It is a real problem for an App Store release. So keep this app private.
- **Change risk.** Spotify has tightened these rules during 2026. The app keeps music behind one replaceable module, so we can switch to local audio files if Spotify closes the door.

## 4. Getting the apps onto your devices

| Account | Result |
|---|---|
| Free | Apps stop after 7 days. You must rebuild and reinstall. Limit 3 apps per device and 3 devices. [docs] Apple TV installs are possible, but the sources are old. [reports] |
| Paid Apple Developer Program | About 1 year per install [reports]. About 99 USD per year. [memory] TestFlight is included. [docs] |

**Decision: start with the free account.** We need only 2 apps on 2 devices, which is inside the limits.

To deal with the 7-day limit, we add one command on the Mac. It rebuilds and reinstalls both apps. You run it before a game, with both devices on the network. Reinstalling over the existing app keeps your presets. [memory]

Free-account limits that matter:

- Services such as iCloud are not available on a free account. [memory] This design does not need them. The app can export presets to a backup file.
- The spike must confirm that a free install works on your Apple TV with the current tvOS.

You can buy the paid account later with no change to the code.

Alternative, if the weekly reinstall becomes annoying and you do not want to pay: a Mac app that runs on your own Mac has no 7-day limit. [memory] It controls Hue and Spotify, and shows the image on the Apple TV through AirPlay. The cost is that the iPad becomes a web page, not a native app.

The app does not need App Store review. Xcode 27.2 is already on your Mac.

## 5. Proposed design

**Preset model:**

```
Campaign → Location → Preset
Preset = name, thumbnail, Hue scene, Spotify playlist + shuffle + volume, image, transition time
```

**Firing a preset.** The iPad sends all three commands at the same time. Each system has its own module with the same interface.

- If one system fails, the other two still work. A session must not stop because of Spotify.
- Each preset tile shows a status per system, with a retry button.

**Pre-session check screen.** One screen with four lights: Hue bridge, Apple TV connected, images synced, Spotify device visible. You see the problems before the players arrive. This also handles the "sleeping speaker" problem.

**Technology:** Swift and SwiftUI for both apps, with a shared Swift package for the model and the network messages. There is no backend. Spotify login uses OAuth with PKCE, so the app holds no secret. [memory]

## 6. Suggested order of work

1. **Throwaway spike.** Answer the three real unknowns: does Spotify reliably start on your speaker, does a Hue scene fire from the iPad, and does the Apple TV app receive a message.
2. **First usable version.** Presets, one-tap firing, image sync, pre-session check.
3. **Table polish.** Crossfades, looping video (fog, fire), volume fades, campaign organisation.
4. **Optional.** Sound-effect pads, lightning via the Entertainment API, keeping track of "where the party is".

## 7. Existing products

I ran one search and found no app that covers all three systems. Results were Hue-only iPad apps, and Everlight, a macOS Hue app built for a DM. This search was not exhaustive.

## 8. What I need from you

1. **Computer:** is this Mac the computer that plays Spotify at the table?
2. **Image:** do you want still images only, or also moving loops?
3. **Scenes:** do you accept creating light scenes in the Hue app, not in our app?

## Sources

Spotify:
- [February 2026 Web API changelog](https://developer.spotify.com/documentation/web-api/references/changes/february-2026)
- [February 2026 migration guide](https://developer.spotify.com/documentation/web-api/tutorials/february-2026-migration-guide)
- [Start playback reference](https://developer.spotify.com/documentation/web-api/reference/start-a-users-playback)
- [July 2026 quota update](https://developer.spotify.com/blog/2026-07-23-web-api-quota-updates)
- [iOS SDK documentation](https://developer.spotify.com/documentation/ios)
- [SPTAppRemote reference](https://spotify.github.io/ios-sdk/html/Classes/SPTAppRemote.html)
- [TechCrunch on Development Mode changes](https://techcrunch.com/2026/02/06/spotify-changes-developer-mode-api-to-require-premium-accounts-limits-test-users/)
- [Forum: activating a device through the API](https://community.spotify.com/t5/Spotify-for-Developers/active-a-playback-device-with-API/m-p/4963267)
- [Forum: Web API error reports](https://community.spotify.com/t5/Spotify-for-Developers/Spotify-Web-API-returns-an-error/td-p/5448044)

Apple:
- [Presenting content on a connected display](https://developer.apple.com/documentation/uikit/presenting-content-on-a-connected-display.md)
- [Bonjour in the Network framework](https://developer.apple.com/documentation/network/bonjour.md)
- [Compare memberships](https://developer.apple.com/support/compare-memberships/)
- [Program overview](https://developer.apple.com/help/account/membership/programs-overview/)
- [9to5Mac: free Apple ID sideloading](https://9to5mac.com/2016/03/27/how-to-create-free-apple-developer-account-sideload-apps/)
- [Redmond Pie: sideloading on Apple TV](https://redmondpie.com/?p=201328)

Hue (official docs did not appear in search, so these are third-party):
- [OpenHue API description](https://jentic.com/apis/openhue.io/openhue)
- [HueMCP](https://pypi.org/project/huemcp/)
- [Everlight, a Hue app for a DM](https://github.com/JRiggles/Everlight)
