import { spawnSync } from "node:child_process";
import { mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = fileURLToPath(new URL("../", import.meta.url));
const PROHIBITED = [
  "privateKeyToAccount",
  "mnemonicToAccount",
  "sendTransaction",
  "writeContract",
  "--broadcast"
];
const SAFETY_ROOTS = [
  "packages/sdk/src",
  "packages/cli/src",
  "examples/developer"
];
const ALLOWED_FILES = {
  "@degenhood/sdk": ["LICENSE", "README.md", "package.json", "src/index.js"],
  "@degenhood/cli": [
    "LICENSE",
    "README.md",
    "package.json",
    "src/args.js",
    "src/cli.js",
    "src/commands.js"
  ]
};

const run = (command, args, { cwd = ROOT } = {}) => {
  const result = spawnSync(command, args, {
    cwd,
    encoding: "utf8",
    env: { ...process.env, npm_config_update_notifier: "false" }
  });
  if (result.status !== 0) {
    throw new Error([
      `${command} ${args.join(" ")} failed with status ${result.status}`,
      result.stdout.trim(),
      result.stderr.trim()
    ].filter(Boolean).join("\n"));
  }
  return result.stdout.trim();
};

const listFiles = async (directory) => {
  const entries = await readdir(directory, { withFileTypes: true });
  const paths = await Promise.all(entries.map(async (entry) => {
    const path = join(directory, entry.name);
    return entry.isDirectory() ? listFiles(path) : [path];
  }));
  return paths.flat();
};

const scanSafetyBoundary = async () => {
  for (const relativeRoot of SAFETY_ROOTS) {
    for (const file of await listFiles(resolve(ROOT, relativeRoot))) {
      const source = await readFile(file, "utf8");
      for (const primitive of PROHIBITED) {
        if (source.includes(primitive)) {
          throw new Error(`Prohibited custody or broadcast primitive "${primitive}" found in ${file}`);
        }
      }
    }
  }
};

const pack = (packageDirectory, destination) => {
  const output = run("npm", [
    "pack",
    resolve(ROOT, packageDirectory),
    "--json",
    "--pack-destination",
    destination
  ]);
  const [metadata] = JSON.parse(output);
  if (!metadata?.filename || !metadata?.name) {
    throw new Error(`npm pack returned incomplete metadata for ${packageDirectory}`);
  }

  const actualFiles = metadata.files.map(({ path }) => path).sort();
  const allowedFiles = [...(ALLOWED_FILES[metadata.name] || [])].sort();
  if (JSON.stringify(actualFiles) !== JSON.stringify(allowedFiles)) {
    throw new Error([
      `${metadata.name} tarball contents differ from the release allowlist`,
      `expected: ${allowedFiles.join(", ")}`,
      `actual: ${actualFiles.join(", ")}`
    ].join("\n"));
  }
  return join(destination, metadata.filename);
};

const verifyInstalledManifest = async (project, packageName) => {
  const manifestPath = join(project, "node_modules", ...packageName.split("/"), "package.json");
  const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
  if (manifest.version !== "0.1.0") {
    throw new Error(`${packageName} installed unexpected version ${manifest.version}`);
  }
  const sdkDependency = manifest.dependencies?.["@degenhood/sdk"];
  if (typeof sdkDependency === "string" && sdkDependency.startsWith("file:")) {
    throw new Error(`${packageName} retained a repository-relative SDK dependency`);
  }
};

const temporaryProject = await mkdtemp(join(tmpdir(), "degenhood-package-release-"));
try {
  await scanSafetyBoundary();
  const sdkTarball = pack("packages/sdk", temporaryProject);
  const cliTarball = pack("packages/cli", temporaryProject);

  await writeFile(join(temporaryProject, "package.json"), JSON.stringify({
    name: "degenhood-package-release-proof",
    private: true,
    type: "module"
  }, null, 2));
  run("npm", [
    "install",
    sdkTarball,
    cliTarball,
    "--ignore-scripts",
    "--no-audit",
    "--no-fund"
  ], { cwd: temporaryProject });

  await Promise.all([
    verifyInstalledManifest(temporaryProject, "@degenhood/sdk"),
    verifyInstalledManifest(temporaryProject, "@degenhood/cli")
  ]);
  run(process.execPath, [
    "--input-type=module",
    "--eval",
    'const sdk = await import("@degenhood/sdk"); if (typeof sdk.createDegenHoodClient !== "function") process.exit(1);'
  ], { cwd: temporaryProject });

  const executable = join(
    temporaryProject,
    "node_modules",
    ".bin",
    process.platform === "win32" ? "degenhood.cmd" : "degenhood"
  );
  const help = run(executable, ["--help"], { cwd: temporaryProject });
  if (!help.includes("degenhood launch prepare")) {
    throw new Error(`Installed ${basename(executable)} did not return the expected help text`);
  }

  process.stdout.write("Package release verification passed from an empty project.\n");
} finally {
  await rm(temporaryProject, { recursive: true, force: true });
}
