import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { createServer } from "node:http";
import { after, before, test } from "node:test";
import { fileURLToPath } from "node:url";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { assertFails, assertSucceeds, initializeTestEnvironment } from "@firebase/rules-unit-testing";
import { initializeApp } from "firebase-admin/app";
import { getAuth } from "firebase-admin/auth";
import { getStorage } from "firebase-admin/storage";
import { doc, getDoc, setDoc } from "firebase/firestore";
import { ref, uploadBytes } from "firebase/storage";
import sharp from "sharp";

const here = dirname(fileURLToPath(import.meta.url));
const projectId = "demo-mirage";
const email = "gm@example.com";
const bucketName = `${projectId}.firebasestorage.app`;
let client;
let uid;
let bridgeDown = false;
const created = [];

const ROOM = "11111111-1111-4111-8111-111111111111";
const COLOR_LIGHT = "22222222-2222-4222-8222-222222222222";
const WHITE_LIGHT = "33333333-3333-4333-8333-333333333333";
const NEW_SCENE = "44444444-4444-4444-8444-444444444444";

const bridgeData = {
  "/clip/v2/resource/room": [{ id: ROOM, metadata: { name: "Table" }, children: [{ rid: "d1", rtype: "device" }, { rid: "d2", rtype: "device" }] }],
  "/clip/v2/resource/zone": [],
  "/clip/v2/resource/light": [
    { id: COLOR_LIGHT, metadata: { name: "Lamp" }, owner: { rid: "d1" }, color: {}, dimming: {} },
    { id: WHITE_LIGHT, metadata: { name: "Bulb" }, owner: { rid: "d2" }, dimming: {} },
  ],
  "/clip/v2/resource/scene": [{ id: NEW_SCENE, metadata: { name: "Old" }, group: { rid: ROOM } }],
};

const fakeBridge = createServer((request, response) => {
  if (bridgeDown) return request.socket.destroy();
  let body = "";
  request.on("data", (chunk) => (body += chunk));
  request.on("end", () => {
    if (request.method !== "GET") created.push({ method: request.method, url: request.url, body: body && JSON.parse(body) });
    const data = request.method === "GET" ? bridgeData[request.url] : [{ rid: NEW_SCENE }];
    response.setHeader("Content-Type", "application/json");
    response.end(JSON.stringify({ data }));
  });
});

const call = async (name, args = {}) => {
  const response = await client.callTool({ name, arguments: args });
  return { ...response, value: response.isError ? undefined : JSON.parse(response.content[0].text) };
};

before(async () => {
  const app = initializeApp({ projectId, storageBucket: bucketName });
  uid = (await getAuth(app).createUser({ email })).uid;
  await new Promise((resolve) => fakeBridge.listen(0, "127.0.0.1", resolve));
  client = new Client({ name: "test", version: "1" });
  await client.connect(new StdioClientTransport({
    command: "node",
    args: [join(here, "../dist/index.js")],
    env: { ...process.env, MIRAGE_USER_EMAIL: email, MIRAGE_FIREBASE_PROJECT: projectId, MIRAGE_STORAGE_BUCKET: bucketName, MIRAGE_HUE_TEST_URL: `http://127.0.0.1:${fakeBridge.address().port}` },
  }));
});

after(async () => {
  await client.close();
  fakeBridge.close();
});

test("builds a library and attaches an image", async () => {
  const campaign = (await call("create_campaign", { name: "Curse of Strahd" })).value;
  const location = (await call("create_location", { campaignId: campaign.id, name: "Barovia" })).value;
  const scene = (await call("upsert_scene", {
    locationId: location.id,
    name: "Forest",
    hueSceneID: "00000000-0000-4000-8000-000000000001",
    playlistURI: "spotify:playlist:TestPlaylist123",
  })).value;

  await call("upsert_scene", { id: scene.id, volume: 40 });

  const png = join(here, "fixture.png");
  await sharp({ create: { width: 5000, height: 2000, channels: 3, background: "#123" } }).png().toFile(png);
  const attached = (await call("attach_image", { sceneId: scene.id, source: png })).value;

  const [stored] = await getStorage().bucket(bucketName).file(`users/${uid}/images/${attached.imageHash}.jpg`).download();
  assert.equal(createHash("sha256").update(stored).digest("hex"), attached.imageHash);
  const meta = await sharp(stored).metadata();
  assert.equal(meta.width, 3840);
  assert.equal(meta.format, "jpeg");

  const library = (await call("list_library")).value;
  const listed = library.campaigns[0].locations[0].scenes[0];
  assert.equal(listed.name, "Forest");
  assert.equal(listed.volume, 40);
  assert.equal(listed.shuffle, true);
  assert.equal(listed.imageHash, attached.imageHash);
});

test("rejects bad input", async () => {
  assert.equal((await call("create_location", { campaignId: "missing", name: "x" })).isError, true);
  assert.equal((await call("upsert_scene", { name: "No location" })).isError, true);
  assert.equal((await call("upsert_scene", { locationId: "missing", name: "x" })).isError, true);
  const badUri = await client.callTool({ name: "upsert_scene", arguments: { name: "x", locationId: "y", playlistURI: "http://evil" } });
  assert.equal(badUri.isError, true);
});

test("security rules allow only the owner", async () => {
  const environment = await initializeTestEnvironment({
    projectId,
    firestore: { rules: readFileSync(join(here, "../../firebase/firestore.rules"), "utf8") },
    storage: { rules: readFileSync(join(here, "../../firebase/storage.rules"), "utf8") },
  });
  const owner = environment.authenticatedContext("owner");
  const stranger = environment.authenticatedContext("stranger");
  const anonymous = environment.unauthenticatedContext();
  const path = "users/owner/scenes/one";
  const image = new Uint8Array([1, 2, 3]);
  const jpeg = { contentType: "image/jpeg" };

  await assertSucceeds(setDoc(doc(owner.firestore(), path), { name: "x" }));
  await assertSucceeds(getDoc(doc(owner.firestore(), path)));
  await assertFails(getDoc(doc(stranger.firestore(), path)));
  await assertFails(setDoc(doc(stranger.firestore(), path), { name: "y" }));
  await assertFails(getDoc(doc(anonymous.firestore(), path)));

  await assertSucceeds(uploadBytes(ref(owner.storage(bucketName), "users/owner/images/a.jpg"), image, jpeg));
  await assertFails(uploadBytes(ref(stranger.storage(bucketName), "users/owner/images/b.jpg"), image, jpeg));
  await assertFails(uploadBytes(ref(owner.storage(bucketName), "users/owner/images/c.txt"), image, { contentType: "text/plain" }));
  await environment.cleanup();
});

test("creates Hue scenes at home and saves designs away", async () => {
  const home = (await call("list_hue_home")).value;
  assert.equal(home.cached, false);
  assert.deepEqual(home.groups[0].lights.map((l) => l.hasColor), [true, false]);
  assert.equal((await call("list_hue_scenes")).value[0].id, NEW_SCENE);

  const made = (await call("create_hue_scene", {
    name: "Forest",
    groupId: ROOM,
    color: "#0a3d2a",
    brightness: 30,
    lights: [{ lightId: COLOR_LIGHT, brightness: 60 }],
  })).value;
  assert.equal(made.id, NEW_SCENE);
  const post = created.find((c) => c.method === "POST").body;
  assert.equal(post.group.rid, ROOM);
  assert.equal(post.actions[0].action.dimming.brightness, 60);
  assert.ok(post.actions[0].action.color.xy.y > 0);
  assert.equal(post.actions[1].action.color, undefined, "white light must get no color");

  await call("preview_hue_scene", { sceneId: NEW_SCENE });
  assert.equal(created.at(-1).body.recall.action, "active");
  await call("delete_hue_scene", { sceneId: NEW_SCENE });
  assert.equal(created.at(-1).method, "DELETE");

  bridgeDown = true;
  assert.equal((await call("list_hue_home")).value.cached, true);
  const away = await call("create_hue_scene", { name: "X", groupId: ROOM });
  assert.equal(away.isError, true);
  assert.match(away.content[0].text, /design_lights/);

  const library = (await call("list_library")).value;
  const location = library.campaigns[0].locations[0];
  const designed = await call("design_lights", { sceneId: location.scenes[0].id, name: "Away", groupId: ROOM, color: "#ff0000" });
  assert.equal(designed.value.lights, 2);
  const after = (await call("list_library")).value.campaigns[0].locations[0].scenes[0];
  assert.equal(after.lightDesign.name, "Away");
  assert.equal(after.lightDesign.actions[1].x, undefined);
  bridgeDown = false;
});

test("hex colors convert to Hue xy", async () => {
  const { hexToXy } = await import("../dist/hue.js");
  const red = hexToXy("#ff0000");
  assert.ok(Math.abs(red.x - 0.64) < 0.01 && Math.abs(red.y - 0.33) < 0.01);
});
