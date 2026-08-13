import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const read = (path) => readFile(new URL(`../${path}`, import.meta.url), "utf8");

test("code ownership names the verified repository maintainer without placeholder teams", async () => {
  const owners = await read(".github/CODEOWNERS");

  assert.match(owners, /^\*\s+@degenhood$/m);
  assert.match(owners, /^\/contracts-v4\/\s+@degenhood$/m);
  assert.match(owners, /^\/contracts-hub\/\s+@degenhood$/m);
  assert.match(owners, /^\/\.github\/\s+@degenhood$/m);
  assert.doesNotMatch(owners, /TODO|placeholder|@[\w-]+\/[\w-]+/i);
});

test("pull requests disclose verification, risk, licensing, and DCO sign-off", async () => {
  const template = await read(".github/PULL_REQUEST_TEMPLATE.md");

  for (const requirement of [
    /problem/i,
    /tests? run/i,
    /security/i,
    /compatibility/i,
    /licen[cs]ing/i,
    /Signed-off-by/i,
    /private canonical repository/i,
    /verified public\s+snapshot/i
  ]) {
    assert.match(template, requirement);
  }
});

test("public issue forms route vulnerabilities to private reporting", async () => {
  const [bug, feature, config] = await Promise.all([
    read(".github/ISSUE_TEMPLATE/bug.yml"),
    read(".github/ISSUE_TEMPLATE/feature.yml"),
    read(".github/ISSUE_TEMPLATE/config.yml")
  ]);

  assert.match(bug, /Do not report security vulnerabilities here/i);
  assert.match(feature, /public programmable core/i);
  assert.match(config, /blank_issues_enabled:\s*false/);
  assert.match(config, /security\/advisories\/new/);
});

test("governance documents the canonical port and human-gated release flow", async () => {
  let process;
  try {
    process = await read("docs/public/publication-process.md");
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
    process = await read("docs/publication-process.md");
  }

  assert.match(process, /public pull request[\s\S]*private canonical repository[\s\S]*immutable canonical commit[\s\S]*public release pull request/i);
  assert.match(process, /never merge[\s\S]*directly/i);
  assert.match(process, /branch protection/i);
  assert.match(process, /private vulnerability reporting/i);
  assert.match(process, /secret scanning/i);
  assert.match(process, /human approval/i);
});

test("the repository carries the verbatim Developer Certificate of Origin 1.1", async () => {
  const dco = await read("LICENSES/LicenseRef-DCO-1.1.txt");

  assert.match(dco, /^Developer Certificate of Origin\nVersion 1\.1/m);
  assert.match(dco, /Everyone is permitted to copy and distribute verbatim copies/);
  assert.match(dco, /\(a\)[\s\S]*\(b\)[\s\S]*\(c\)[\s\S]*\(d\)/);
  assert.match(dco, /personal information I submit with it, including my sign-off/);
});
