import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const read = (path) => readFile(new URL(`../${path}`, import.meta.url), "utf8");
const readJson = async (path) => JSON.parse(await read(path));
const releaseVersion = "0.1.0";
const repositoryUrl = "git+https://github.com/degenhood/DegenHood.git";

test("SDK and CLI manifests define independently publishable stable releases", async () => {
  const [sdk, cli] = await Promise.all([
    readJson("packages/sdk/package.json"),
    readJson("packages/cli/package.json")
  ]);

  for (const manifest of [sdk, cli]) {
    assert.equal(manifest.version, releaseVersion);
    assert.equal(manifest.engines?.node, ">=20");
    assert.equal(manifest.publishConfig?.access, "public");
    assert.equal(manifest.publishConfig?.tag, "latest");
    assert.equal(manifest.license, "MIT");
    assert.equal(manifest.repository?.url, repositoryUrl);
    assert.equal(manifest.bugs?.url, "https://github.com/degenhood/DegenHood/issues");
    assert.ok(manifest.files.includes("src"));
    assert.ok(manifest.files.includes("README.md"));
    assert.ok(manifest.files.includes("LICENSE"));
  }

  assert.equal(cli.peerDependencies["@degenhood/sdk"], releaseVersion);
  assert.equal(cli.devDependencies["@degenhood/sdk"], "file:../sdk");
  assert.equal(cli.bin?.degenhood, "src/cli.js");
});

test("quickstart preserves the non-custodial Template 2 launch flow", async () => {
  const [token, example, sdkReadme, cliReadme] = await Promise.all([
    readJson("examples/developer/token.example.json"),
    read("examples/developer/prepare-launch.ts"),
    read("packages/sdk/README.md"),
    read("packages/cli/README.md")
  ]);

  assert.equal(token.templateId, 2);
  for (const role of ["tokenAdmin", "feeAdmin", "beneficiary"]) {
    assert.equal(token[role], undefined, `${role} must default to the creator wallet`);
  }

  for (const behavior of [
    /requestWalletChallenge/,
    /walletClient\.signMessage/,
    /createWalletSession/,
    /prepareLaunch/,
    /verifyLaunchPreparation/,
    /estimateGas/,
    /\.call/
  ]) {
    assert.match(example, behavior);
  }
  assert.doesNotMatch(
    example,
    /privateKey|mnemonic|sendTransaction|writeContract|signTransaction|--broadcast/iu
  );

  for (const readme of [sdkReadme, cliReadme]) {
    assert.match(readme, /@degenhood\/(?:sdk|cli)@0\.1\.0/);
    assert.match(readme, /unsigned|does not (?:sign|store|broadcast)/iu);
  }
});

test("agent skill preserves the verified unsigned launch boundary", async () => {
  const [skill, agent] = await Promise.all([
    read("skills/prepare-degenhood-launch/SKILL.md"),
    read("skills/prepare-degenhood-launch/agents/openai.yaml")
  ]);

  assert.match(skill, /^---\nname: prepare-degenhood-launch\n/);
  for (const reference of [
    "packages/sdk/README.md",
    "packages/cli/README.md",
    "examples/developer/token.example.json",
    "examples/developer/prepare-launch.ts",
    "openapi/degenhood-v1.yaml",
    "SECURITY.md"
  ]) {
    assert.ok(skill.includes(reference), `skill must route agents to ${reference}`);
  }
  for (const requirement of [
    /Robinhood Chain/,
    /4663/,
    /Template 2/,
    /verifyLaunchPreparation/,
    /eth_estimateGas/,
    /eth_call/,
    /\.\.\.de6/,
    /do not sign/iu,
    /do not broadcast/iu,
    /do not deploy/iu,
    /do not move funds/iu,
    /fail closed/iu
  ]) {
    assert.match(skill, requirement);
  }

  assert.match(agent, /display_name: "Prepare DegenHood Launch"/);
  assert.match(agent, /default_prompt: "Use \$prepare-degenhood-launch /);
});
