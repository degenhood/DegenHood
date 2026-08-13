import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const read = (path) => readFile(new URL(`../${path}`, import.meta.url), "utf8");
const readPublicShell = async (canonicalPath, publicPath) => {
  try {
    return await read(canonicalPath);
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
    return read(publicPath);
  }
};
const readJson = async (path) => JSON.parse(await read(path));
const CANARY_VERSION = "0.1.0-canary.0";
const REPOSITORY_URL = "git+https://github.com/degenhood/DegenHood.git";

test("SDK and CLI manifests define independently publishable public release candidates", async () => {
  const [sdk, cli] = await Promise.all([
    readJson("packages/sdk/package.json"),
    readJson("packages/cli/package.json")
  ]);

  for (const manifest of [sdk, cli]) {
    assert.equal(manifest.version, CANARY_VERSION);
    assert.equal(manifest.engines?.node, ">=20");
    assert.equal(manifest.publishConfig?.access, "public");
    assert.equal(manifest.publishConfig?.tag, "canary");
    assert.equal(manifest.license, "MIT");
    assert.equal(manifest.repository?.type, "git");
    assert.equal(manifest.repository?.url, REPOSITORY_URL);
    assert.equal(manifest.homepage, "https://degenhood.fun");
    assert.equal(manifest.bugs?.url, "https://github.com/degenhood/DegenHood/issues");
    assert.match(manifest.description || "", /DegenHood/i);
    assert.ok(manifest.files.includes("src"));
    assert.ok(manifest.files.includes("README.md"));
    assert.ok(manifest.files.includes("LICENSE"));
  }

  assert.equal(cli.peerDependencies["@degenhood/sdk"], CANARY_VERSION);
  assert.equal(cli.devDependencies["@degenhood/sdk"], "file:../sdk");
  assert.equal(cli.dependencies["@degenhood/sdk"], undefined);
  assert.equal(cli.bin?.degenhood, "src/cli.js");
});

test("creator quickstarts preserve the non-custodial Template 2 launch flow", async () => {
  const [token, typescript, sdkReadme, cliReadme] = await Promise.all([
    readJson("examples/developer/token.example.json"),
    read("examples/developer/prepare-launch.ts"),
    read("packages/sdk/README.md"),
    read("packages/cli/README.md")
  ]);

  assert.equal(token.templateId, 2);
  for (const role of ["tokenAdmin", "feeAdmin", "beneficiary"]) {
    assert.equal(token[role], undefined, `${role} must default to the creator wallet`);
  }

  assert.match(typescript, /createDegenHoodClient/);
  assert.match(typescript, /verifyLaunchPreparation/);
  assert.match(typescript, /\.requestWalletChallenge\(/);
  assert.match(typescript, /walletClient\.signMessage\(/);
  assert.match(typescript, /\.createWalletSession\(/);
  assert.match(typescript, /\.prepareLaunch\(/);
  assert.match(typescript, /\.estimateGas\(/);
  assert.match(typescript, /\.call\(/);
  assert.doesNotMatch(
    typescript,
    /privateKey|mnemonic|sendTransaction|writeContract|signTransaction|--broadcast/i
  );

  for (const readme of [sdkReadme, cliReadme]) {
    assert.match(readme, /npm (?:install|i) @degenhood\/(?:sdk|cli)@0\.1\.0-canary\.0/);
    assert.match(readme, /controlled (?:early-access )?canary/i);
    assert.match(readme, /examples\/developer/);
    assert.match(readme, /does not (?:sign|store|broadcast)|unsigned/i);
  }
});

test("agent skill preserves the verified unsigned launch boundary", async () => {
  const [skill, agent, security, repositoryReadme] = await Promise.all([
    read("skills/prepare-degenhood-launch/SKILL.md"),
    read("skills/prepare-degenhood-launch/agents/openai.yaml"),
    read("SECURITY.md"),
    readPublicShell("README.public.md", "README.md")
  ]);

  assert.match(skill, /^---\nname: prepare-degenhood-launch\n/);
  assert.match(skill, /description:.*prepare.*verify.*simulate/i);
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
  assert.doesNotMatch(skill, /docs\/handoffs/);
  for (const requirement of [
    /Robinhood Chain/,
    /4663/,
    /Template 2/,
    /verifyLaunchPreparation/,
    /eth_estimateGas/,
    /eth_call/,
    /\.\.\.de6/
  ]) {
    assert.match(skill, requirement);
  }
  for (const boundary of [
    /private key/i,
    /mnemonic/i,
    /keystore/i,
    /do not sign/i,
    /do not broadcast/i,
    /do not deploy/i,
    /do not move funds/i,
    /fail closed/i
  ]) {
    assert.match(skill, boundary);
  }

  assert.match(agent, /display_name: "Prepare DegenHood Launch"/);
  assert.match(agent, /short_description: "Prepare and verify unsigned DegenHood launches"/);
  assert.match(agent, /default_prompt: "Use \$prepare-degenhood-launch /);
  assert.match(security, /private vulnerability report/i);
  assert.match(security, /GitHub Security Advisories/i);
  assert.doesNotMatch(repositoryReadme, /operator documentation|v3 fallback/i);
});

test("release verification proves exact tarballs from an empty project", async () => {
  const [verifier, publicCore] = await Promise.all([
    read("scripts/verify-package-release.mjs"),
    read("scripts/verify-public-core.sh")
  ]);

  assert.match(verifier, /mkdtemp/);
  assert.match(verifier, /run\("npm", \[\s*"pack"/);
  assert.match(verifier, /README\.md/);
  assert.match(verifier, /src\/index\.js/);
  assert.match(verifier, /src\/cli\.js/);
  assert.match(verifier, /run\("npm", \[\s*"install"/);
  assert.match(verifier, /import\("@degenhood\/sdk"\)/);
  assert.match(verifier, /degenhood/);
  assert.match(verifier, /"--help"/);
  for (const primitive of [
    "privateKeyToAccount",
    "mnemonicToAccount",
    "sendTransaction",
    "writeContract",
    "--broadcast"
  ]) {
    assert.ok(verifier.includes(primitive), `verifier must scan for ${primitive}`);
  }

  assert.match(publicCore, /node --test test\/developerDistribution\.test\.js/);
  assert.match(publicCore, /node scripts\/verify-package-release\.mjs/);
});

test("public developer guidance is self-contained and excludes operator procedures", async () => {
  const [skill, repositoryReadme, security] = await Promise.all([
    read("skills/prepare-degenhood-launch/SKILL.md"),
    readPublicShell("README.public.md", "README.md"),
    read("SECURITY.md")
  ]);

  for (const text of [skill, repositoryReadme, security]) {
    assert.doesNotMatch(text, /production canary packet|production credential|deployment secret/i);
  }
  assert.match(skill, /fail closed/i);
  assert.match(skill, /do not broadcast/i);
  assert.match(repositoryReadme, /Do not use it to\s+construct a new production LaunchHub launch/i);
  assert.match(security, /instead of a public issue/i);
});

test("SDK documents one-transaction LaunchHub claims without weakening the unsigned boundary", async () => {
  const [sdkSource, sdkReadme] = await Promise.all([
    read("packages/sdk/src/index.js"),
    read("packages/sdk/README.md")
  ]);

  assert.match(sdkSource, /buildHubFeeClaimPreparation/);
  assert.match(sdkSource, /verifyHubFeeClaimPreparation/);
  assert.match(sdkSource, /claimFees/);
  assert.match(sdkReadme, /LaunchHub/i);
  assert.match(sdkReadme, /one zero-value, unsigned transaction/i);
  assert.match(sdkReadme, /legacy.*three/i);
  assert.match(sdkReadme, /activated template/i);
  assert.doesNotMatch(
    `${sdkSource}\n${sdkReadme}`,
    /privateKeyToAccount|mnemonicToAccount|sendTransaction|writeContract|signTransaction|--broadcast/
  );
});
