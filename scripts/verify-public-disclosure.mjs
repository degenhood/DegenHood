import { execFile as execFileCallback } from "node:child_process";
import { readFile, readdir, stat } from "node:fs/promises";
import { relative, resolve, sep } from "node:path";
import { pathToFileURL } from "node:url";
import { promisify } from "node:util";

const execFile = promisify(execFileCallback);

const recursiveFiles = async (root, directory = root) => {
  const files = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    if ([".git", "node_modules", "out", "cache"].includes(entry.name)) continue;
    const path = resolve(directory, entry.name);
    if (entry.isDirectory()) files.push(...await recursiveFiles(root, path));
    else if (entry.isFile()) files.push(relative(root, path).split(sep).join("/"));
  }
  return files;
};

const filesToScan = async (root) => {
  try {
    const { stdout } = await execFile("git", ["ls-files", "-z"], {
      cwd: root,
      encoding: "buffer"
    });
    return stdout.toString("utf8").split("\0").filter(Boolean);
  } catch {
    return recursiveFiles(root);
  }
};

const textRules = [
  ["workstation-path", /(?:^|[\s("'`])(?:\/Users\/[^/\s]+|\/home\/[^/\s]+|[A-Za-z]:\\Users\\[^\\\s]+)(?:[\/\\]|$)/m],
  ["workstation-path", /(?:\.config\/superpowers|Downloads\/degenhood|file:\/\/\/)/i],
  ["private-key-block", /-----BEGIN [A-Z ]*PRIVATE KEY-----/],
  ["credential", /\bgh[pousr]_[A-Za-z0-9]{20,}\b/],
  ["credential", /\bsk-[A-Za-z0-9_-]{20,}\b/],
  ["credential", /\bxox[baprs]-[A-Za-z0-9-]{10,}\b/],
  ["credential", /\bAKIA[0-9A-Z]{16}\b/]
];

const forbiddenFile = (path) => {
  const name = path.split("/").at(-1);
  if (path === "apps" || path.startsWith("apps/")) return "forbidden-path";
  if (name === ".env" || (name.startsWith(".env.") && name !== ".env.example")) {
    return "sensitive-file";
  }
  if (/\.(?:db|jks|key|keystore|p12|pem|pfx|sqlite|sqlite3)$/i.test(name)) {
    return "sensitive-file";
  }
  return null;
};

const escapedRegExp = (value) => value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

export const scanPublicDisclosure = async (rootValue, { forbiddenTerms = [] } = {}) => {
  const root = resolve(rootValue);
  const findings = [];
  for (const path of await filesToScan(root)) {
    const pathFinding = forbiddenFile(path);
    if (pathFinding) findings.push({ path, kind: pathFinding });

    const absolute = resolve(root, path);
    let info;
    try {
      info = await stat(absolute);
    } catch {
      continue;
    }
    if (!info.isFile()) continue;
    const content = await readFile(absolute);
    if (content.includes(0)) continue;
    const text = content.toString("utf8");
    for (const [kind, rule] of textRules) {
      if (rule.test(text)) findings.push({ path, kind });
    }
    for (const term of forbiddenTerms.filter(Boolean)) {
      if (new RegExp(escapedRegExp(term), "i").test(text)) {
        findings.push({ path, kind: "forbidden-identity" });
      }
    }
  }
  return findings.sort((left, right) => (
    left.path.localeCompare(right.path) || left.kind.localeCompare(right.kind)
  ));
};

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const root = process.argv[2] || ".";
  const forbiddenTerms = [];
  for (let index = 3; index < process.argv.length; index += 1) {
    if (process.argv[index] !== "--forbidden-term" || !process.argv[index + 1]) {
      throw new Error("usage: verify-public-disclosure.mjs <root> [--forbidden-term <value>]...");
    }
    forbiddenTerms.push(process.argv[index + 1]);
    index += 1;
  }
  const findings = await scanPublicDisclosure(root, { forbiddenTerms });
  if (findings.length > 0) {
    process.stderr.write(`${JSON.stringify({ status: "rejected", findings }, null, 2)}\n`);
    process.exitCode = 1;
  } else {
    process.stdout.write(`${JSON.stringify({ status: "accepted", findings: 0 })}\n`);
  }
}
