import { pathToFileURL } from "node:url";
import { createDegenHoodClient } from "../packages/sdk/src/index.js";

const ADDRESS = /^0x[0-9a-fA-F]{40}$/;

const required = (env, key) => {
  const value = String(env[key] || "").trim();
  if (!value) throw new Error(`${key} is required`);
  return value;
};

export async function runDeveloperLaneSmoke({
  env = process.env,
  fetch = globalThis.fetch,
  log = console.log
} = {}) {
  const baseUrl = required(env, "DEGENHOOD_API_URL");
  const token = required(env, "DEGENHOOD_TOKEN");
  if (!ADDRESS.test(token)) throw new Error("DEGENHOOD_TOKEN must be a valid address");

  const client = createDegenHoodClient({ baseUrl, fetch });
  const health = await client.getHealth();
  if (health?.ok !== true) throw new Error("DegenHood API health check failed");
  if (health.indexer?.stale === true || health.indexer?.reorgHalted === true) {
    throw new Error("DegenHood indexer is not ready");
  }
  log(`health ok · store=${health.store || "unknown"} · tokens=${health.tokens ?? "unknown"}`);

  const record = await client.getToken(token);
  if (String(record?.contract || "").toLowerCase() !== token.toLowerCase()) {
    throw new Error("Indexed token response does not match DEGENHOOD_TOKEN");
  }
  const symbol = String(record.sym || record.symbol || "unknown").toUpperCase();
  log(`$${symbol} indexed · contract=${record.contract}`);

  if (env.DEGENHOOD_RUN_PREPARATION_SMOKE !== "true") {
    return { health: "ok", token: symbol, preparation: "skipped" };
  }

  const accessToken = String(env.DEGENHOOD_ACCESS_TOKEN || "").trim();
  const launcher = String(env.DEGENHOOD_SMOKE_LAUNCHER || "").trim();
  if (!accessToken || !ADDRESS.test(launcher)) {
    throw new Error("A valid access token and launcher are required for preparation smoke");
  }

  const authenticated = createDegenHoodClient({ baseUrl, accessToken, fetch });
  const preparation = await authenticated.prepareLaunch({
    name: "DegenHood API Smoke",
    symbol: "DHSMOKE",
    launcher,
    tokenAdmin: launcher,
    feeAdmin: launcher,
    beneficiary: launcher,
    description: "Unsigned preparation smoke. Never broadcast.",
    templateId: Number(env.DEGENHOOD_SMOKE_TEMPLATE_ID || 2)
  });
  const verified = authenticated.verifyPreparation(preparation);
  log(`preparation verified · predicted=${verified.predictedTokenAddress} · digest=${verified.requestDigest}`);

  return {
    health: "ok",
    token: symbol,
    preparation: "verified",
    predictedTokenAddress: verified.predictedTokenAddress,
    requestDigest: verified.requestDigest
  };
}

const isMain = process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;
if (isMain) {
  runDeveloperLaneSmoke().catch((error) => {
    console.error(`developer-lane smoke failed: ${error.message}`);
    process.exitCode = 1;
  });
}
