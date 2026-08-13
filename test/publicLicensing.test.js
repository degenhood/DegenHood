import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const read = (path) => readFile(new URL(`../${path}`, import.meta.url), "utf8");
const readReuse = async () => {
  try {
    return await read("REUSE.toml");
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
    return read("public-repository/REUSE.toml");
  }
};

test("the public repository carries the exact standard licence texts", async () => {
  const [mit, ccBy, root] = await Promise.all([
    read("LICENSES/MIT.txt"),
    read("LICENSES/CC-BY-4.0.txt"),
    read("LICENSE")
  ]);

  assert.match(mit, /^MIT License/m);
  assert.match(mit, /Copyright \(c\) <year> <copyright holders>/);
  assert.match(mit, /Permission is hereby granted, free of charge/);
  assert.match(ccBy, /Attribution 4\.0 International/);
  assert.match(ccBy, /Section 1 -- Definitions/);
  assert.match(ccBy, /Section 8 -- Interpretation/);
  assert.match(root, /Copyright \(c\) 2026 DegenHood contributors/);
});

test("brand material has an explicit rights-reserved licence reference", async () => {
  const terms = await read("LICENSES/LicenseRef-DegenHood-Brand.txt");

  for (const protectedMaterial of [
    "DegenHood name",
    "logos",
    "character designs",
    "pack artwork",
    "trade dress"
  ]) {
    assert.match(terms, new RegExp(protectedMaterial, "i"));
  }
  assert.match(terms, /No trademark licence is granted/i);
  assert.match(terms, /All rights reserved/i);
});

test("REUSE metadata maps public software and documentation without private web paths", async () => {
  const reuse = await readReuse();

  assert.match(reuse, /^version\s*=\s*1/m);
  assert.match(reuse, /path\s*=\s*"\*\*"[\s\S]*SPDX-License-Identifier\s*=\s*"MIT"/);
  assert.match(reuse, /path\s*=\s*\[[^\]]*"README\.md"[^\]]*"docs\/\*\*"[^\]]*\][\s\S]*SPDX-License-Identifier\s*=\s*"CC-BY-4\.0"/);
  assert.doesNotMatch(reuse, /apps\/web/);

  const defaultIndex = reuse.indexOf('SPDX-License-Identifier = "MIT"');
  const docsIndex = reuse.indexOf('SPDX-License-Identifier = "CC-BY-4.0"');
  assert.ok(defaultIndex < docsIndex, "documentation mapping must override the default");
});

test("all first-party public packages identify MIT software licensing", async () => {
  for (const path of [
    "packages/sdk/package.json",
    "packages/cli/package.json"
  ]) {
    const pkg = JSON.parse(await read(path));
    assert.equal(pkg.license, "MIT", `${path} must identify its software licence`);
  }
});

test("the human-readable licence map matches the machine-readable policy", async () => {
  const licensing = await read("LICENSING.md");

  assert.match(licensing, /first-party public software[\s\S]*MIT/i);
  assert.match(licensing, /documentation[\s\S]*CC BY 4\.0/i);
  assert.match(licensing, /brand assets[\s\S]*all rights reserved/i);
  assert.match(licensing, /REUSE\.toml/);
});

test("third-party notices describe only dependencies in the public protocol core", async () => {
  const [notices, notice, reuse] = await Promise.all([
    read("THIRD_PARTY_NOTICES.md"),
    read("NOTICE.md"),
    readReuse()
  ]);

  assert.match(notices, /OpenZeppelin/i);
  assert.match(notices, /Uniswap/i);
  assert.match(notices, /viem/i);
  assert.doesNotMatch(notices, /Privy|Reown|WalletConnect|MetaMask/i);
  assert.match(notice, /THIRD_PARTY_NOTICES\.md/);
  assert.doesNotMatch(reuse, /LicenseRef-(?:Reown|WalletConnect|MetaMask)/);
});
