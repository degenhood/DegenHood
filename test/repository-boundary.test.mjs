import assert from "node:assert/strict";
import { access, readFile } from "node:fs/promises";
import test from "node:test";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");

const exists = async (path) => {
  try {
    await access(resolve(root, path));
    return true;
  } catch {
    return false;
  }
};

test("publishes only the developer-tooling repository boundary", async () => {
  for (const required of [
    "packages/sdk/package.json",
    "packages/cli/package.json",
    "examples/developer/prepare-launch.ts",
    "openapi/degenhood-v1.yaml",
    "skills/prepare-degenhood-launch/SKILL.md"
  ]) {
    assert.equal(await exists(required), true, `missing public developer file: ${required}`);
  }

  for (const prohibited of ["apps", "contracts", "contracts-v4", "docs"]) {
    assert.equal(await exists(prohibited), false, `private application scope leaked: ${prohibited}`);
  }
});

test("public documentation does not point contributors into private app paths", async () => {
  for (const path of ["README.md", "CONTRIBUTING.md", "SECURITY.md"]) {
    const source = await readFile(resolve(root, path), "utf8");
    assert.doesNotMatch(source, /\bapps\/|\bcontracts-v4\/|\bBFF\b/iu, `${path} references private app scope`);
  }
});
