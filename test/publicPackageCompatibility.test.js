import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const root = new URL("../", import.meta.url);

const source = (path) => readFile(new URL(path, root), "utf8");
const mappedSource = async (canonicalPath, publicPath) => {
  try {
    return await source(canonicalPath);
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
    return source(publicPath);
  }
};

test("public surfaces identify SDK and CLI 0.1.x as legacy v4-factory tooling", async () => {
  const [publicReadme, compatibility, sdk, cli, openapi] = await Promise.all([
    mappedSource("README.public.md", "README.md"),
    source("COMPATIBILITY.md"),
    source("packages/sdk/README.md"),
    source("packages/cli/README.md"),
    source("openapi/degenhood-v1.yaml")
  ]);

  for (const [name, body] of Object.entries({ publicReadme, compatibility, sdk, cli, openapi })) {
    assert.match(body, /legacy v4[ -]factory/i, `${name} must state the legacy target`);
    assert.match(body, /production LaunchHub/i, `${name} must distinguish the current launch path`);
  }

  assert.match(compatibility, /0\.1\.x/);
  assert.match(compatibility, /0x7E20ef986E5cA961D3fB40eBADd51c27c6274176/);
  assert.match(compatibility, /ca7d76493b8150a6f1c7a32d5ea9a94dadfd592b3277657d8216327ffbac33df/i);
  assert.doesNotMatch(publicReadme, /client\.prepareLaunch\(/);
});

test("public contribution policy is open, reviewable and DCO based", async () => {
  const [contributing, licensing, agents] = await Promise.all([
    source("CONTRIBUTING.md"),
    source("LICENSING.md"),
    mappedSource("AGENTS.public.md", "AGENTS.md")
  ]);

  assert.match(contributing, /public pull request/i);
  assert.match(contributing, /Developer Certificate of Origin/i);
  assert.match(contributing, /MIT/);
  assert.match(licensing, /All first-party public software/i);
  assert.match(agents, /accepted public change/i);
});
