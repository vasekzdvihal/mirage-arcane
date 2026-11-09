import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { CollectionReference, DocumentReference } from "firebase-admin/firestore";
import { z } from "zod";
import { BridgeUnreachable, buildDesign, HueBridge, loadConfig, type DesignInput, type HueGroup } from "./hue.js";

const AWAY =
  "The Hue Bridge is not reachable, so this Mac is probably away from home. " +
  "Use design_lights to save a light design. The iPad creates it on the bridge when it is home.";

const hex = z.string().regex(/^#[0-9a-fA-F]{6}$/).describe("Color as #RRGGBB");
const brightness = z.number().min(0).max(100).describe("0 turns the light off");
const design = {
  name: z.string().min(1).max(32).describe("Hue scene name, at most 32 characters"),
  groupId: z.string().uuid().describe("Room or zone id from list_hue_home"),
  color: hex.optional().describe("Default color for every light in the group"),
  brightness: brightness.optional().describe("Default brightness for every light. 100 when omitted"),
  lights: z
    .array(z.object({ lightId: z.string().uuid(), color: hex.optional(), brightness: brightness.optional() }))
    .optional()
    .describe("Per-light values that override the defaults"),
};

interface Context {
  homeDocument: () => Promise<DocumentReference>;
  scenes: () => Promise<CollectionReference>;
}

function json(value: unknown) {
  return { content: [{ type: "text" as const, text: JSON.stringify(value, null, 2) }] };
}

function failure(message: string) {
  return { isError: true, content: [{ type: "text" as const, text: message }] };
}

async function bridge(): Promise<HueBridge> {
  const config = await loadConfig();
  if (!config) throw new Error("The Hue Bridge is not paired. Run: node mcp/dist/hue-pair.js <bridge-host>");
  return new HueBridge(config);
}

/** Runs a bridge action, and explains the situation when the Mac is away from home. */
async function live<T>(action: (bridge: HueBridge) => Promise<T>) {
  try {
    return json(await action(await bridge()));
  } catch (error) {
    return failure(error instanceof BridgeUnreachable ? AWAY : (error as Error).message);
  }
}

export function registerHueTools(server: McpServer, context: Context): void {
  const cachedGroups = async (): Promise<HueGroup[] | undefined> =>
    (await (await context.homeDocument()).get()).data()?.groups as HueGroup[] | undefined;

  const findGroup = async (load: () => Promise<HueGroup[] | undefined>, groupId: string) => {
    const group = (await load())?.find((g) => g.id === groupId);
    if (!group) throw new Error(`No room or zone with id ${groupId}. Call list_hue_home first.`);
    return group;
  };

  server.registerTool(
    "list_hue_home",
    {
      description:
        "List Hue rooms and zones with their lights, and whether each light supports color. " +
        "Away from home, this returns the last saved copy with cached: true.",
      inputSchema: {},
    },
    async () => {
      try {
        const groups = await (await bridge()).groups();
        await (await context.homeDocument()).set({ groups, savedAt: new Date().toISOString() });
        return json({ cached: false, groups });
      } catch (error) {
        if (!(error instanceof BridgeUnreachable)) return failure((error as Error).message);
        const groups = await cachedGroups();
        return groups ? json({ cached: true, groups }) : failure(AWAY);
      }
    },
  );

  server.registerTool(
    "list_hue_scenes",
    {
      description: "List the scenes on the Hue Bridge with their ids. Use an id as hueSceneID in upsert_scene.",
      inputSchema: {},
    },
    async () => live((b) => b.scenes()),
  );

  server.registerTool(
    "create_hue_scene",
    {
      description:
        "Create a scene on the Hue Bridge from colors and brightness. Pass replaceSceneId to change an existing scene. " +
        "Works only when this Mac is on the home network.",
      inputSchema: { ...design, replaceSceneId: z.string().uuid().optional() },
    },
    async ({ groupId, replaceSceneId, ...input }) =>
      live(async (b) => {
        const built = buildDesign(await findGroup(() => b.groups(), groupId), input as DesignInput);
        if (replaceSceneId) {
          await b.updateScene(replaceSceneId, built);
          return { id: replaceSceneId, name: built.name, lights: built.actions.length };
        }
        return { id: await b.createScene(built), name: built.name, lights: built.actions.length };
      }),
  );

  server.registerTool(
    "preview_hue_scene",
    { description: "Show a scene on the real lights.", inputSchema: { sceneId: z.string().uuid() } },
    async ({ sceneId }) => live(async (b) => (await b.recallScene(sceneId), { previewing: sceneId })),
  );

  server.registerTool(
    "delete_hue_scene",
    { description: "Delete a scene from the Hue Bridge. This cannot be undone.", inputSchema: { sceneId: z.string().uuid() } },
    async ({ sceneId }) => live(async (b) => (await b.deleteScene(sceneId), { deleted: sceneId })),
  );

  server.registerTool(
    "design_lights",
    {
      description:
        "Save a light design on a library scene, for use away from home. It needs no connection to the bridge. " +
        "The iPad creates the Hue scene when it is home, then links it to the library scene.",
      inputSchema: { sceneId: z.string().min(1).describe("Library scene id from list_library"), ...design },
    },
    async ({ sceneId, groupId, ...input }) => {
      try {
        const scenes = await context.scenes();
        if (!(await scenes.doc(sceneId).get()).exists) return failure(`No scene with id ${sceneId}.`);
        const built = buildDesign(await findGroup(cachedGroups, groupId), input as DesignInput);
        await scenes.doc(sceneId).update({ lightDesign: built });
        return json({ sceneId, savedDesign: built.name, lights: built.actions.length });
      } catch (error) {
        return failure((error as Error).message);
      }
    },
  );
}
