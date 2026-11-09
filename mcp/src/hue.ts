import { mkdir, readFile, writeFile } from "node:fs/promises";
import http from "node:http";
import https from "node:https";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { HUE_ROOTS } from "./hue-roots.js";

export interface HueConfig {
  host: string;
  key: string;
  bridgeId: string;
}

export interface HueLight {
  id: string;
  name: string;
  hasColor: boolean;
  hasDimming: boolean;
}

export interface HueGroup {
  id: string;
  type: "room" | "zone";
  name: string;
  lights: HueLight[];
}

export class BridgeUnreachable extends Error {}

const configPath = join(homedir(), ".config", "mirage-arcane", "hue.json");

export async function loadConfig(): Promise<HueConfig | undefined> {
  if (testUrl()) return { host: "test", key: "test", bridgeId: "test" };
  try {
    return JSON.parse(await readFile(configPath, "utf8")) as HueConfig;
  } catch {
    return undefined;
  }
}

export async function saveConfig(config: HueConfig): Promise<void> {
  await mkdir(dirname(configPath), { recursive: true, mode: 0o700 });
  await writeFile(configPath, JSON.stringify(config, null, 2), { mode: 0o600 });
}

/** Test runs talk to a fake bridge. Only a loopback address is accepted. */
function testUrl(): URL | undefined {
  const value = process.env.MIRAGE_HUE_TEST_URL;
  if (!value) return undefined;
  const url = new URL(value);
  if (url.protocol !== "http:" || url.hostname !== "127.0.0.1") throw new Error("Bad MIRAGE_HUE_TEST_URL.");
  return url;
}

export interface RawResponse {
  status: number;
  body: string;
}

/** Sends one request. The certificate must chain to a Hue root. `bridgeId` also pins the certificate's name. */
export function rawRequest(
  host: string,
  method: string,
  path: string,
  options: { key?: string; bridgeId?: string; body?: unknown } = {},
): Promise<RawResponse> {
  const payload = options.body === undefined ? undefined : JSON.stringify(options.body);
  const headers: Record<string, string | number> = {};
  if (options.key) headers["hue-application-key"] = options.key;
  if (payload) {
    headers["Content-Type"] = "application/json";
    headers["Content-Length"] = Buffer.byteLength(payload);
  }

  return new Promise((resolve, reject) => {
    const fake = testUrl();
    const done = (response: http.IncomingMessage) => {
      const chunks: Buffer[] = [];
      response.on("data", (chunk: Buffer) => chunks.push(chunk));
      response.on("end", () =>
        resolve({ status: response.statusCode ?? 0, body: Buffer.concat(chunks).toString("utf8") }),
      );
    };
    const request = fake
      ? http.request({ host: fake.hostname, port: fake.port, method, path, headers, timeout: 5000 }, done)
      : https.request(
          {
            host,
            method,
            path,
            headers,
            timeout: 5000,
            ca: HUE_ROOTS,
            checkServerIdentity: (_name, certificate) =>
              options.bridgeId && String(certificate.subject.CN).toLowerCase() !== options.bridgeId
                ? new Error("The bridge certificate does not match the paired bridge.")
                : undefined,
          },
          done,
        );
    request.on("timeout", () => request.destroy(new Error("timeout")));
    request.on("error", (error: NodeJS.ErrnoException) => {
      if (error.message.includes("does not match")) reject(error);
      else reject(new BridgeUnreachable(`The Hue Bridge is not reachable (${error.code ?? error.message}).`));
    });
    if (payload) request.write(payload);
    request.end();
  });
}

export class HueBridge {
  constructor(private readonly config: HueConfig) {}

  private async call<T>(method: string, path: string, body?: unknown): Promise<T> {
    const response = await rawRequest(this.config.host, method, `/clip/v2/resource/${path}`, {
      key: this.config.key,
      bridgeId: this.config.bridgeId,
      body,
    });
    if (response.status < 200 || response.status >= 300) {
      throw new Error(`Hue bridge HTTP ${response.status}: ${response.body.slice(0, 300)}`);
    }
    return JSON.parse(response.body) as T;
  }

  async groups(): Promise<HueGroup[]> {
    type Item = { id: string; metadata?: { name: string }; children?: { rid: string; rtype: string }[] };
    type LightItem = { id: string; metadata: { name: string }; owner: { rid: string }; color?: unknown; dimming?: unknown };
    const [rooms, zones, lights] = await Promise.all([
      this.call<{ data: Item[] }>("GET", "room"),
      this.call<{ data: Item[] }>("GET", "zone"),
      this.call<{ data: LightItem[] }>("GET", "light"),
    ]);
    const describe = (light: LightItem): HueLight => ({
      id: light.id,
      name: light.metadata.name,
      hasColor: Boolean(light.color),
      hasDimming: Boolean(light.dimming),
    });
    const inGroup = (item: Item, field: "owner" | "id") =>
      lights.data
        .filter((light) =>
          item.children?.some((child) => child.rid === (field === "owner" ? light.owner.rid : light.id)),
        )
        .map(describe);
    return [
      ...rooms.data.map((r) => ({ id: r.id, type: "room" as const, name: r.metadata?.name ?? "Room", lights: inGroup(r, "owner") })),
      ...zones.data.map((z) => ({ id: z.id, type: "zone" as const, name: z.metadata?.name ?? "Zone", lights: inGroup(z, "id") })),
    ];
  }

  async scenes(): Promise<{ id: string; name: string; groupId: string }[]> {
    const scenes = await this.call<{ data: { id: string; metadata: { name: string }; group: { rid: string } }[] }>(
      "GET",
      "scene",
    );
    return scenes.data.map((s) => ({ id: s.id, name: s.metadata.name, groupId: s.group.rid }));
  }

  async createScene(design: LightDesign): Promise<string> {
    const reply = await this.call<{ data: { rid: string }[] }>("POST", "scene", {
      type: "scene",
      metadata: { name: design.name },
      group: { rid: design.groupId, rtype: design.groupType },
      actions: design.actions.map(toClipAction),
    });
    return reply.data[0]!.rid;
  }

  async updateScene(id: string, design: LightDesign): Promise<void> {
    await this.call("PUT", `scene/${id}`, { metadata: { name: design.name }, actions: design.actions.map(toClipAction) });
  }

  async recallScene(id: string): Promise<void> {
    await this.call("PUT", `scene/${id}`, { recall: { action: "active", duration: 1000 } });
  }

  async deleteScene(id: string): Promise<void> {
    await this.call("DELETE", `scene/${id}`);
  }
}

export interface LightAction {
  lightId: string;
  on: boolean;
  brightness?: number;
  x?: number;
  y?: number;
}

export interface LightDesign {
  name: string;
  groupId: string;
  groupType: "room" | "zone";
  actions: LightAction[];
}

function toClipAction(action: LightAction) {
  return {
    target: { rid: action.lightId, rtype: "light" },
    action: {
      on: { on: action.on },
      ...(action.brightness === undefined ? {} : { dimming: { brightness: action.brightness } }),
      ...(action.x === undefined || action.y === undefined ? {} : { color: { xy: { x: action.x, y: action.y } } }),
    },
  };
}

/** Converts an sRGB hex color to the CIE xy values that Hue uses. */
export function hexToXy(hex: string): { x: number; y: number } {
  const channel = (index: number) => {
    const value = parseInt(hex.slice(1 + index * 2, 3 + index * 2), 16) / 255;
    return value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4;
  };
  const [r, g, b] = [channel(0), channel(1), channel(2)];
  const X = r * 0.4124 + g * 0.3576 + b * 0.1805;
  const Y = r * 0.2126 + g * 0.7152 + b * 0.0722;
  const Z = r * 0.0193 + g * 0.1192 + b * 0.9505;
  const sum = X + Y + Z;
  if (sum === 0) return { x: 0.3127, y: 0.329 };
  return { x: Number((X / sum).toFixed(4)), y: Number((Y / sum).toFixed(4)) };
}

export interface LightInput {
  lightId: string;
  color?: string;
  brightness?: number;
}

export interface DesignInput {
  name: string;
  color?: string;
  brightness?: number;
  lights?: LightInput[];
}

/** Builds one action per light in the group. A light's own values win over the group's defaults. */
export function buildDesign(group: HueGroup, input: DesignInput): LightDesign {
  const unknown = input.lights?.find((light) => !group.lights.some((l) => l.id === light.lightId));
  if (unknown) throw new Error(`Light ${unknown.lightId} is not in ${group.name}.`);

  const actions = group.lights.map((light): LightAction => {
    const own = input.lights?.find((l) => l.lightId === light.id);
    const color = own?.color ?? input.color;
    const brightness = own?.brightness ?? input.brightness ?? 100;
    if (brightness === 0) return { lightId: light.id, on: false };
    return {
      lightId: light.id,
      on: true,
      ...(light.hasDimming ? { brightness } : {}),
      ...(light.hasColor && color ? hexToXy(color) : {}),
    };
  });
  return { name: input.name, groupId: group.id, groupType: group.type, actions };
}
