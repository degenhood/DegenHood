import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import {
  loadPublicDeployments,
  renderPublicDeployments
} from "../scripts/render-public-deployments.mjs";

const root = new URL("../", import.meta.url);

test("typed production deployment graph renders the committed public reference", async () => {
  const deployments = await loadPublicDeployments(root);
  const rendered = renderPublicDeployments(deployments);
  let committed;
  try {
    committed = await readFile(new URL("docs/public/deployments.md", root), "utf8");
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
    committed = await readFile(new URL("docs/deployments.md", root), "utf8");
  }

  assert.equal(deployments.network.chainId, 4663);
  assert.equal(deployments.reconciliation.blockNumber, 35474835);
  assert.equal(
    deployments.reconciliation.blockHash,
    "0xb373803c8bae7e9efc0e88f8aa730614cdb5b85095bbce0b921cf5331d5461ea"
  );
  assert.equal(deployments.reconciliation.status, "runtime-and-explorer-reconciled");
  assert.equal(rendered, committed);
});

test("every first-party deployment has a full address, explorer link and public source", async () => {
  const deployments = await loadPublicDeployments(root);
  const entries = deployments.groups.flatMap((group) => group.contracts);

  assert.equal(entries.length, 19);
  for (const entry of entries) {
    assert.match(entry.address, /^0x[0-9a-fA-F]{40}$/);
    assert.match(entry.source, /^contracts-(?:hub|v4|degenetics)\/src\/.+\.sol$/);
  }
});

test("Degenetics is a first-class deployed contract family with exact source provenance", async () => {
  const deployments = await loadPublicDeployments(root);
  const group = deployments.groups.find(({ title }) => title === "Degenetics · DegenHood Degens");
  assert.ok(group, "Degenetics deployment group is required");

  const expected = new Map([
    ["DegenHood Degens", "0xf449B45DcF716E3ee679CDdbB87EB3d9ED34e71b"],
    ["Hood Conductor", "0x800C6304da5752AF135459e4790Bb4b795C5E9C8"],
    ["v4 price source", "0x39cc8CEF2Dbc735F5B1cEaD3F6006095Fc84C7C0"],
    ["LP fee forwarder", "0xD2428d2190bc383d9d34706f9BDD591290aab857"],
    ["Royalty forwarder", "0x011508A95f4C97F34182676316236901c273E5C1"],
    ["Fee flusher", "0xE0731f4adA23BF193278188Bd3BE2407F56817De"]
  ]);
  assert.equal(group.contracts.length, expected.size);
  for (const contract of group.contracts) {
    assert.equal(contract.address, expected.get(contract.name));
    assert.match(contract.sourceCommit, /^[0-9a-f]{40}$/);
    assert.match(contract.source, /^contracts-degenetics\/src\/.+\.sol$/);
  }
});

test("deployment rows identify the explorer-compiled main sources", async () => {
  const deployments = await loadPublicDeployments(root);
  const byName = new Map(
    deployments.groups.flatMap((group) => group.contracts).map((entry) => [entry.name, entry])
  );

  assert.equal(
    byName.get("Token deployer")?.source,
    "contracts-hub/src/deployers/DegenHoodTokenV5Deployer.sol"
  );
  assert.equal(
    byName.get("WETH LP locker")?.source,
    "contracts-hub/src/launchhub-v3/DegenV3LpLocker.sol"
  );
  assert.equal(
    byName.get("SPY LP locker")?.source,
    "contracts-hub/src/launchhub-spy-v3/DegenSpyV3LpLocker.sol"
  );
});
