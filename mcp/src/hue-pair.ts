#!/usr/bin/env node
// Pairs this Mac with a Hue Bridge. Usage: node dist/hue-pair.js <bridge-host>
// Find the host with: dns-sd -B _hue._tcp, then use the bridge's <id>.local name.
// Pairing is a command, not an MCP tool, so an agent cannot mint bridge credentials.
import { rawRequest, saveConfig } from "./hue.js";

const host = process.argv[2];
if (!host) {
  console.error("Usage: hue-pair <bridge-host>");
  process.exit(1);
}

const info = JSON.parse((await rawRequest(host, "GET", "/api/0/config")).body) as { bridgeid: string };
const bridgeId = info.bridgeid.toLowerCase();
console.log("Press the button on the Hue Bridge. Waiting up to 5 minutes.");

for (let attempt = 0; attempt < 150; attempt++) {
  const response = await rawRequest(host, "POST", "/api", { bridgeId, body: { devicetype: "mirage_arcane#mac" } });
  const [reply] = JSON.parse(response.body) as [{ success?: { username: string }; error?: { type: number; description: string } }];
  if (reply.success) {
    await saveConfig({ host, key: reply.success.username, bridgeId });
    console.log("PAIRED");
    process.exit(0);
  }
  if (reply.error?.type !== 101) {
    console.error(`Pairing failed: ${reply.error?.description}`);
    process.exit(1);
  }
  await new Promise((resolve) => setTimeout(resolve, 2000));
}
console.error("TIMEOUT: the button was not pressed.");
process.exit(1);
