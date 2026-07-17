import assert from "node:assert/strict";
import test from "node:test";
import { runDeveloperLaneSmoke } from "../scripts/smoke-developer-lane.mjs";

const token = "0x04d5D8a61DA0b6548B136412843aDBA55EbeaDE6";

test("read-only smoke uses the public API URL and does not require authentication", async () => {
  const requests = [];
  const result = await runDeveloperLaneSmoke({
    env: {
      DEGENHOOD_API_URL: "https://api.degenhood.fun",
      DEGENHOOD_TOKEN: token
    },
    fetch: async (url, options) => {
      requests.push({ url, options });
      const body = url.endsWith("/health")
        ? { ok: true, indexer: { stale: false, reorgHalted: false }, tokens: 1 }
        : { contract: token, symbol: "DEGEN" };
      return new Response(JSON.stringify(body), {
        status: 200,
        headers: { "content-type": "application/json" }
      });
    },
    log: () => {}
  });

  assert.deepEqual(result, { health: "ok", token: "DEGEN", preparation: "skipped" });
  assert.deepEqual(requests.map(({ url }) => url), [
    "https://api.degenhood.fun/health",
    `https://api.degenhood.fun/api/token/${token}`
  ]);
  for (const { options } of requests) {
    assert.equal(options.headers.authorization, undefined);
  }
});
