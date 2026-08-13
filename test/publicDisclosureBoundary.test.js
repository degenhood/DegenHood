import assert from "node:assert/strict";
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import test from "node:test";

import { scanPublicDisclosure } from "../scripts/verify-public-disclosure.mjs";

const put = async (root, path, value) => {
  const target = join(root, path);
  await mkdir(dirname(target), { recursive: true });
  await writeFile(target, value);
};

test("public disclosure scan rejects workstation paths, private product code and named identities", async () => {
  const root = await mkdtemp(join(tmpdir(), "degenhood-disclosure-red-"));
  try {
    const workstationPath = ["", "Users", "example-user", "Downloads", "project", "apps", "web"].join("/");
    const forbiddenIdentity = ["example", "handle"].join("-");
    await put(root, "README.md", `cd ${workstationPath}\ncontact ${forbiddenIdentity}\n`);
    await put(root, "apps/private-product/src/App.jsx", "export default function App() {}\n");

    const findings = await scanPublicDisclosure(root, { forbiddenTerms: [forbiddenIdentity] });
    assert.ok(findings.some(({ kind }) => kind === "workstation-path"));
    assert.ok(findings.some(({ kind }) => kind === "forbidden-path"));
    assert.ok(findings.some(({ kind }) => kind === "forbidden-identity"));
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("public disclosure scan accepts repository-relative protocol documentation", async () => {
  const root = await mkdtemp(join(tmpdir(), "degenhood-disclosure-green-"));
  try {
    await put(root, "README.md", "Run `./scripts/verify-public-core.sh` from the repository root.\n");
    await put(root, "contracts-degenetics/src/Degens.sol", "contract Degens {}\n");
    const absentIdentity = ["absent", "handle"].join("-");
    assert.deepEqual(await scanPublicDisclosure(root, { forbiddenTerms: [absentIdentity] }), []);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
