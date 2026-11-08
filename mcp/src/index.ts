#!/usr/bin/env node
import { createHash } from "node:crypto";
import { readFile, stat } from "node:fs/promises";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { applicationDefault, initializeApp } from "firebase-admin/app";
import { getAuth } from "firebase-admin/auth";
import { getFirestore, type DocumentData } from "firebase-admin/firestore";
import { getStorage } from "firebase-admin/storage";
import sharp from "sharp";
import { z } from "zod";

const projectId = process.env.MIRAGE_FIREBASE_PROJECT ?? "mirage-arcane";
const email = process.env.MIRAGE_USER_EMAIL;
if (!email) {
  console.error("Set MIRAGE_USER_EMAIL to the Google account that owns the data.");
  process.exit(1);
}

const usesEmulator = Boolean(process.env.FIRESTORE_EMULATOR_HOST);
const app = initializeApp({
  projectId,
  storageBucket: process.env.MIRAGE_STORAGE_BUCKET ?? `${projectId}.firebasestorage.app`,
  ...(usesEmulator ? {} : { credential: applicationDefault() }),
});
const db = getFirestore(app);
const bucket = getStorage(app).bucket();

let cachedUid: string | undefined;
async function uid(): Promise<string> {
  cachedUid ??= (await getAuth(app).getUserByEmail(email!)).uid;
  return cachedUid;
}

async function collection(name: "campaigns" | "locations" | "scenes") {
  return db.collection("users").doc(await uid()).collection(name);
}

function result(value: unknown) {
  return { content: [{ type: "text" as const, text: JSON.stringify(value, null, 2) }] };
}

function failure(message: string) {
  return { isError: true, content: [{ type: "text" as const, text: message }] };
}

const byOrder = (a: DocumentData, b: DocumentData) =>
  (a.order ?? Number.MAX_SAFE_INTEGER) - (b.order ?? Number.MAX_SAFE_INTEGER) ||
  String(a.name).localeCompare(String(b.name));

const server = new McpServer({ name: "mirage-arcane", version: "0.1.0" });

server.registerTool(
  "list_library",
  {
    description:
      "List all campaigns, each with its locations and scenes. Call this first to get the ids the other tools need.",
    inputSchema: {},
  },
  async () => {
    const [campaigns, locations, scenes] = await Promise.all([
      collection("campaigns").then((c) => c.get()),
      collection("locations").then((c) => c.get()),
      collection("scenes").then((c) => c.get()),
    ]);
    const sceneList = scenes.docs.map((d) => ({ id: d.id, ...d.data() }));
    const locationList = locations.docs.map((d) => ({ id: d.id, ...d.data() })) as DocumentData[];
    return result({
      campaigns: campaigns.docs
        .map((d) => ({ id: d.id, ...d.data() }))
        .sort(byOrder)
        .map((campaign) => ({
          ...campaign,
          locations: locationList
            .filter((l) => l.campaignId === campaign.id)
            .sort(byOrder)
            .map((location) => ({
              ...location,
              scenes: sceneList.filter((s) => (s as DocumentData).locationId === location.id).sort(byOrder),
            })),
        })),
    });
  },
);

server.registerTool(
  "create_campaign",
  {
    description: "Create a campaign, the top level of the library.",
    inputSchema: { name: z.string().min(1), order: z.number().int().optional() },
  },
  async ({ name, order }) => {
    const reference = await (await collection("campaigns")).add({ name, order: order ?? 0 });
    return result({ id: reference.id, name });
  },
);

server.registerTool(
  "create_location",
  {
    description: "Create a location inside a campaign, such as Barovia or Castle Ravenloft.",
    inputSchema: { campaignId: z.string().min(1), name: z.string().min(1), order: z.number().int().optional() },
  },
  async ({ campaignId, name, order }) => {
    if (!(await (await collection("campaigns")).doc(campaignId).get()).exists) {
      return failure(`No campaign with id ${campaignId}.`);
    }
    const reference = await (await collection("locations")).add({ campaignId, name, order: order ?? 0 });
    return result({ id: reference.id, name });
  },
);

server.registerTool(
  "upsert_scene",
  {
    description:
      "Create a scene, or update one when id is given. On update, only the fields you pass change. " +
      "hueSceneID is the Hue CLIP v2 scene id. playlistURI is a Spotify URI. Use attach_image for the picture.",
    inputSchema: {
      id: z.string().min(1).optional(),
      locationId: z.string().min(1).optional().describe("Required when creating a scene"),
      name: z.string().min(1).optional().describe("Required when creating a scene"),
      order: z.number().int().optional(),
      hueSceneID: z.string().uuid().nullable().optional(),
      hueDynamic: z.boolean().optional().describe("True plays the Hue scene's animated palette"),
      playlistURI: z.string().regex(/^spotify:(playlist|album):[A-Za-z0-9]+$/).nullable().optional(),
      playlistName: z.string().nullable().optional(),
      shuffle: z.boolean().optional(),
      volume: z.number().int().min(0).max(100).nullable().optional(),
      fadeSeconds: z.number().min(0).max(10).optional(),
    },
  },
  async ({ id, ...fields }) => {
    if (fields.locationId && !(await (await collection("locations")).doc(fields.locationId).get()).exists) {
      return failure(`No location with id ${fields.locationId}.`);
    }
    const scenes = await collection("scenes");
    if (id) {
      if (!(await scenes.doc(id).get()).exists) return failure(`No scene with id ${id}.`);
      await scenes.doc(id).update(fields);
      return result({ id, updated: Object.keys(fields) });
    }
    if (!fields.name || !fields.locationId) return failure("A new scene needs name and locationId.");
    const reference = await scenes.add({
      ...fields,
      shuffle: fields.shuffle ?? true,
      hueDynamic: fields.hueDynamic ?? false,
      fadeSeconds: fields.fadeSeconds ?? 2,
    });
    return result({ id: reference.id, name: fields.name });
  },
);

server.registerTool(
  "delete_scene",
  {
    description: "Delete one scene. This cannot be undone.",
    inputSchema: { id: z.string().min(1) },
  },
  async ({ id }) => {
    await (await collection("scenes")).doc(id).delete();
    return result({ deleted: id });
  },
);

const MAX_SOURCE_BYTES = 50 * 1024 * 1024;

async function loadImage(source: string): Promise<Buffer> {
  if (!/^https?:\/\//.test(source)) {
    if ((await stat(source)).size > MAX_SOURCE_BYTES) throw new Error("The image file is too large.");
    return readFile(source);
  }
  const response = await fetch(source, { signal: AbortSignal.timeout(30_000) });
  if (!response.ok) throw new Error(`Download failed: HTTP ${response.status}`);
  if (Number(response.headers.get("content-length") ?? 0) > MAX_SOURCE_BYTES) {
    throw new Error("The image is too large.");
  }
  const body = Buffer.from(await response.arrayBuffer());
  if (body.length > MAX_SOURCE_BYTES) throw new Error("The image is too large.");
  return body;
}

server.registerTool(
  "attach_image",
  {
    description:
      "Set a scene's projector image from a local file path or an http(s) URL. The image is fitted inside 4K and stored as JPEG.",
    inputSchema: { sceneId: z.string().min(1), source: z.string().min(1) },
  },
  async ({ sceneId, source }) => {
    const scenes = await collection("scenes");
    if (!(await scenes.doc(sceneId).get()).exists) return failure(`No scene with id ${sceneId}.`);
    const jpeg = await sharp(await loadImage(source))
      .rotate()
      .resize({ width: 3840, height: 3840, fit: "inside", withoutEnlargement: true })
      .jpeg({ quality: 88 })
      .toBuffer();
    const imageHash = createHash("sha256").update(jpeg).digest("hex");
    await bucket.file(`users/${await uid()}/images/${imageHash}.jpg`).save(jpeg, { contentType: "image/jpeg" });
    await scenes.doc(sceneId).update({ imageHash });
    return result({ sceneId, imageHash, bytes: jpeg.length });
  },
);

await server.connect(new StdioServerTransport());
