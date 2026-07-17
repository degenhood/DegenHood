#!/usr/bin/env node
import { readFile } from "node:fs/promises";
import { createDegenHoodClient } from "@degenhood/sdk";
import { createPublicClient, http } from "viem";
import { buildLaunchInput, parseCliArgs } from "./args.js";
import { inspectFeeDeliveryPreparation, launchStatus, prepareFeeDelivery, simulatePreparation, verifyPreparationDocument } from "./commands.js";

const usage = `Usage:
  degenhood launch prepare --file token.json --account 0x... [--api URL] [--access-token TOKEN]
  degenhood launch verify --file preparation.json
  degenhood launch simulate --file preparation.json --rpc URL
  degenhood launch status --token 0x... [--api URL]
  degenhood fees inspect --token 0x... [--api URL]
  degenhood fees prepare --token 0x... [--api URL]

Commands only inspect or prepare unsigned transactions. The CLI never reads a
private key, signs, delivers fees, broadcasts, or pays gas.`;

const readDocument = async (file) => JSON.parse(await readFile(file, "utf8"));

async function main() {
  if (process.argv.includes("--help") || process.argv.includes("-h")) {
    process.stdout.write(`${usage}\n`);
    return;
  }
  const args = parseCliArgs(process.argv.slice(2));
  const api = args.api || process.env.DEGENHOOD_API_URL || "https://api.degenhood.fun";
  let result;
  if (args.command === "launch.prepare") {
    const accessToken = args.accessToken || process.env.DEGENHOOD_ACCESS_TOKEN || "";
    if (!accessToken) throw new Error("Provide --access-token or DEGENHOOD_ACCESS_TOKEN");
    const input = buildLaunchInput(await readDocument(args.file), args.account);
    const client = createDegenHoodClient({ baseUrl: api, accessToken });
    result = await client.prepareLaunch(input);
    client.verifyPreparation(result);
  } else if (args.command === "launch.verify") {
    result = verifyPreparationDocument(await readDocument(args.file));
  } else if (args.command === "launch.simulate") {
    const rpc = args.rpc || process.env.DEGENHOOD_RPC_URL;
    if (!rpc) throw new Error("Provide --rpc or DEGENHOOD_RPC_URL");
    result = await simulatePreparation(await readDocument(args.file), {
      client: createPublicClient({ transport: http(rpc) })
    });
  } else if (args.command === "launch.status") {
    result = await launchStatus(args.token, {
      client: createDegenHoodClient({ baseUrl: api })
    });
  } else {
    const preparation = await prepareFeeDelivery(args.token, {
      client: createDegenHoodClient({ baseUrl: api })
    });
    result = args.command === "fees.inspect"
      ? inspectFeeDeliveryPreparation(preparation)
      : preparation;
  }
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
}

main().catch((error) => {
  process.stderr.write(`degenhood: ${error.message}\n\n${usage}\n`);
  process.exitCode = 1;
});
