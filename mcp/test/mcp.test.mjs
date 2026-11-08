import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
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

const call = async (name, args = {}) => {
  const response = await client.callTool({ name, arguments: args });
  return { ...response, value: response.isError ? undefined : JSON.parse(response.content[0].text) };
};

before(async () => {
  const app = initializeApp({ projectId, storageBucket: bucketName });
  uid = (await getAuth(app).createUser({ email })).uid;
  client = new Client({ name: "test", version: "1" });
  await client.connect(new StdioClientTransport({
    command: "node",
    args: [join(here, "../dist/index.js")],
    env: { ...process.env, MIRAGE_USER_EMAIL: email, MIRAGE_FIREBASE_PROJECT: projectId, MIRAGE_STORAGE_BUCKET: bucketName },
  }));
});

after(async () => client.close());

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
