# Backend

Firebase holds the scene library. The iPad and the MCP server both read and write it. Hue keys and Spotify tokens stay in the iPad Keychain and never reach Firebase.

```
Claude ── MCP (stdio, on the Mac) ──▶ Firestore + Storage ◀── live sync ── iPad app
          firebase-admin                                     Google login
```

## Data

All paths sit under `users/{uid}`. Collections are flat and linked by id.

| Path | Fields |
|---|---|
| `campaigns/{id}` | `name`, `order` |
| `locations/{id}` | `campaignId`, `name`, `order` |
| `scenes/{id}` | `locationId`, `name`, `order`, `hueSceneID`, `hueDynamic`, `playlistURI`, `playlistName`, `shuffle`, `volume`, `imageHash`, `fadeSeconds` |

Images are JPEGs in Storage at `users/{uid}/images/{sha256}.jpg`, at most 4K.

Security rules in `firebase/` allow access only to the owner. Adding more users needs no data move.

## iPad (`iPad/Cloud.swift`)

- Login is Google through Firebase Auth. Sign in with Apple is not possible on a free Apple account.
- Three live listeners keep campaigns, locations and scenes current. Firestore's device cache keeps them available with no connection.
- Missing images download automatically and are checked against their hash. Images stay in the local image folder.
- The first login on an empty account uploads the local scenes into "My Campaign".
- A build with no `GoogleService-Info.plist` still runs, with cloud features off.

## MCP server (`mcp/`)

Runs on the Mac and uses Application Default Credentials. It finds the owner through `MIRAGE_USER_EMAIL`.

| Tool | Purpose |
|---|---|
| `list_library` | All campaigns, locations and scenes with their ids |
| `create_campaign`, `create_location` | Build the structure |
| `upsert_scene` | Create a scene, or change fields of one |
| `delete_scene` | Delete one scene |
| `attach_image` | Set a scene image from a file or URL |

Register it with Claude Code:

```bash
pnpm --dir mcp install && pnpm --dir mcp build
claude mcp add mirage-arcane -e MIRAGE_USER_EMAIL=<your google email> -- node "$PWD/mcp/dist/index.js"
```

### Hue tools

The same server talks to the bridge directly. The key sits in `~/.config/mirage-arcane/hue.json`, outside the repo. The bridge certificate is checked against Hue's root CA and the paired bridge id.

| Tool | Purpose | Needs home network |
|---|---|---|
| `list_hue_home` | Rooms, zones, lights. Saves a copy to Firestore. Away, returns that copy | No |
| `list_hue_scenes` | Bridge scenes with ids, for `upsert_scene` | Yes |
| `create_hue_scene` | Create or replace a scene from colors and brightness | Yes |
| `preview_hue_scene`, `delete_hue_scene` | Show on the real lights, or remove | Yes |
| `design_lights` | Save a design on a library scene | No |

A design stays in `scenes/{id}.lightDesign`. When the iPad has a paired bridge in reach, it creates the Hue scene, sets `hueSceneID` and clears the design. It tries when scenes change and when the app comes to the front.

Pair once with the button pressed. Pairing is deliberately a command, not an MCP tool:

```bash
node mcp/dist/hue-pair.js <bridge-id>.local   # find it with: dns-sd -B _hue._tcp
```

## Live project

Project `mirage-arcane`, on the Blaze plan. Firestore is in `nam5`. It was created in the default region when rules were first deployed. The Storage bucket is `mirage-arcane.firebasestorage.app` in `US-CENTRAL1`. Check in the console that a budget alert exists.

## Firebase project setup

Manual, in the Firebase console:

1. Create the project. If the id is not `mirage-arcane`, update `.firebaserc` and set `MIRAGE_FIREBASE_PROJECT` for the MCP server.
2. Upgrade to the Blaze plan. Add a budget alert. An alert warns but does not stop spending.
3. Open Authentication, enable the Google provider.

From the command line:

1. Create Firestore, and the default Storage bucket in `US-CENTRAL1`. Only US-CENTRAL1, US-EAST1 and US-WEST1 get the free tier.
2. Register an iOS app with bundle id `cz.zdvihal.miragearcane.ipad`.
3. Deploy rules: `pnpm dlx firebase-tools@latest deploy --only firestore:rules,storage`
4. Run `scripts/firebase-config.sh`, then `scripts/install.sh`.

The generated `GoogleService-Info.plist` and `Firebase.local.xcconfig` are gitignored, because this repo is public.
