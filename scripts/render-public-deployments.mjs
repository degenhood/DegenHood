import { access, readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

export const loadPublicDeployments = async (root = new URL("../", import.meta.url)) => (
  JSON.parse(await readFile(new URL("public-repository/deployments.json", root), "utf8"))
);

const shortAddress = (address) => `${address.slice(0, 6)}…${address.slice(-4)}`;

const contractTable = (group, explorer) => [
  `## ${group.title}`,
  "",
  "| Component | Address | Public source |",
  "| --- | --- | --- |",
  ...group.contracts.map((entry) => (
    `| ${entry.name} | [\`${shortAddress(entry.address)}\`](${explorer}/address/${entry.address}) | \`${entry.source}\` |`
  )),
  ""
];

export const renderPublicDeployments = (value) => {
  const lines = [
    "# Production deployments",
    "",
    `> **Reconciliation:** ${value.network.name} block \`${value.reconciliation.blockNumber}\``,
    `> (\`${value.reconciliation.blockHash}\`) on ${value.reconciliation.date}. All`,
    `> ${value.reconciliation.firstPartyRuntimeMatches} first-party runtime hashes matched Blockscout's deployed-bytecode records and all`,
    `> ${value.reconciliation.dependencyCodePresent} listed dependencies had code. Blockscout labels all ${value.reconciliation.blockscoutVerified} first-party entries verified:`,
    `> ${value.reconciliation.blockscoutFullyVerified} fully and ${value.reconciliation.blockscoutPartiallyVerified} partially. ${value.reconciliation.exactMainSourceMatches} main source files match exactly; the remaining`,
    `> difference is comment-only. This reconciliation is evidence, not an independent audit.`,
    "",
    `Network: ${value.network.name} (\`chainId ${value.network.chainId}\`)`,
    "",
    `Explorer: [${new URL(value.network.explorer).host}](${value.network.explorer})`,
    "",
    "Names, tickers, logos and websites can be copied. The full address and chain ID are the contract's",
    "identity.",
    ""
  ];

  for (const group of value.groups) lines.push(...contractTable(group, value.network.explorer));

  lines.push(
    "## Canonical dependencies",
    "",
    "| Component | Address |",
    "| --- | --- |",
    ...value.dependencies.map((entry) => `| ${entry.name} | \`${entry.address}\` |`),
    "",
    "## Verification procedure",
    "",
    `1. Confirm chain ID \`${value.network.chainId}\` from an independent RPC.`,
    "2. Resolve code and state at the recorded block and store its hash.",
    "3. Compile the stated public source with the pinned compiler and settings.",
    "4. Compare runtime bytecode, accounting for published immutable values and metadata.",
    "5. Confirm LaunchHub domain/template activation and every configured authority.",
    "6. Link the resulting evidence from the tagged public release.",
    ""
  );
  return lines.join("\n");
};

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const root = new URL("../", import.meta.url);
  const rendered = renderPublicDeployments(await loadPublicDeployments(root));
  let destination = new URL("docs/public/deployments.md", root);
  try {
    await access(new URL("docs/public", root));
  } catch {
    destination = new URL("docs/deployments.md", root);
  }
  await writeFile(destination, rendered);
}
