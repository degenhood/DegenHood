import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const read = (path) => readFile(new URL(`../${path}`, import.meta.url), "utf8");

test("public CI is self-contained, least-privilege, and immutable", async () => {
  const [ci, codeql] = await Promise.all([
    read(".github/workflows/ci.yml"),
    read(".github/workflows/codeql.yml")
  ]);

  assert.match(ci, /^permissions:\n  contents: read$/m);
  assert.match(ci, /persist-credentials: false/);
  assert.match(ci, /submodules: recursive/);
  assert.match(ci, /\.\/scripts\/verify-public-core\.sh/);
  assert.match(ci, /npm audit --prefix packages\/sdk --omit=dev --audit-level=high/);
  assert.match(ci, /contracts-degenetics/);
  assert.match(ci, /\.\/scripts\/install-dependencies\.sh/);
  assert.match(ci, /forge fmt --check/);
  assert.match(ci, /forge test/);
  assert.match(ci, /test\/production\/\*\.t\.sol/);

  for (const forbidden of [
    "apps/",
    "verify-developer-lane",
    "DEGENHOOD_BASE_REF",
    "pull_request_target",
    "secrets."
  ]) {
    assert.ok(!ci.includes(forbidden), `CI must not depend on ${forbidden}`);
  }

  assert.match(codeql, /security-events: write/);
  assert.doesNotMatch(codeql, /pull_request_target|secrets\./);

  for (const workflow of [ci, codeql]) {
    for (const match of workflow.matchAll(/uses:\s+([^\s]+)/g)) {
      assert.match(match[1], /@[0-9a-f]{40}$/i, `${match[1]} must be commit-pinned`);
    }
  }
});

test("the public verification entry point exercises every published product lane", async () => {
  const script = await read("scripts/verify-public-core.sh");

  assert.match(script, /^#!\/usr\/bin\/env bash/);
  assert.match(script, /set -euo pipefail/);
  assert.match(script, /git diff --check/);
  assert.match(script, /test\/public\*\.test\.js/);
  assert.match(script, /test\/developerDistribution\.test\.js/);
  assert.match(script, /scripts\/verify-package-release\.mjs/);
  assert.match(script, /npm test --prefix packages\/sdk/);
  assert.match(script, /npm test --prefix packages\/cli/);
  assert.match(script, /verify-public-disclosure\.mjs/);
  assert.doesNotMatch(script, /apps\/|docs\/handoffs|private-service/);
});

test("public dependency updates cover only exported ecosystems", async () => {
  const dependabot = await read(".github/dependabot.yml");

  for (const directory of ["/packages/sdk", "/packages/cli"]) {
    assert.ok(dependabot.includes(`directory: "${directory}"`), `${directory} must be covered`);
  }
  assert.doesNotMatch(dependabot, /directory: "\/apps\//);
  assert.match(dependabot, /package-ecosystem: "github-actions"/);
  assert.match(dependabot, /package-ecosystem: "gitsubmodule"/);
});
