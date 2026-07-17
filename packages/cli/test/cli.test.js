import test from "node:test";
import assert from "node:assert/strict";
import { buildLaunchInput, parseCliArgs } from "../src/args.js";
import { buildV4FeeDeliveryPreparation, buildV4LaunchRequest, encodeV4LaunchCalldata, launchRequestDigest, serializeV4LaunchRequest } from "@degenhood/sdk";
import { inspectFeeDeliveryPreparation, launchStatus, prepareFeeDelivery, simulatePreparation, verifyPreparationDocument } from "../src/commands.js";

const account = "0x1111111111111111111111111111111111111111";

test("CLI parses the thin launch prepare command", () => {
  assert.deepEqual(parseCliArgs([
    "launch", "prepare", "--file", "token.json", "--account", account,
    "--api", "https://degenhood.fun", "--access-token", "secret"
  ]), {
    command: "launch.prepare",
    file: "token.json",
    account,
    api: "https://degenhood.fun",
    accessToken: "secret"
  });
});

test("CLI binds launcher and default roles to the creator-funded account", () => {
  assert.deepEqual(buildLaunchInput({
    name: "SDK Token", symbol: "sdk", description: "creator story", templateId: 2
  }, account), {
    name: "SDK Token",
    symbol: "sdk",
    description: "creator story",
    templateId: 2,
    launcher: account,
    tokenAdmin: account,
    feeAdmin: account,
    beneficiary: account
  });
});

test("CLI rejects broadcast and private-key options", () => {
  assert.throws(() => parseCliArgs([
    "launch", "prepare", "--file", "token.json", "--account", account, "--private-key", "0xsecret"
  ]), /unsupported option/i);
  assert.throws(() => parseCliArgs(["launch", "send"]), /only supports/i);
});

test("CLI parses verify, simulate and status without signing options", () => {
  assert.deepEqual(parseCliArgs(["launch", "verify", "--file", "preparation.json"]), {
    command: "launch.verify", file: "preparation.json"
  });
  assert.deepEqual(parseCliArgs([
    "launch", "simulate", "--file", "preparation.json", "--rpc", "https://rpc.example"
  ]), {
    command: "launch.simulate", file: "preparation.json", rpc: "https://rpc.example"
  });
  assert.deepEqual(parseCliArgs(["launch", "simulate", "--file", "preparation.json"]), {
    command: "launch.simulate", file: "preparation.json"
  });
  assert.deepEqual(parseCliArgs([
    "launch", "status", "--token", account, "--api", "https://api.example"
  ]), {
    command: "launch.status", token: account, api: "https://api.example"
  });
});

test("CLI parses fee inspection and unsigned preparation without delivery options", () => {
  assert.deepEqual(parseCliArgs(["fees", "inspect", "--token", account]), {
    command: "fees.inspect", token: account
  });
  assert.deepEqual(parseCliArgs([
    "fees", "prepare", "--token", account, "--api", "https://api.example"
  ]), {
    command: "fees.prepare", token: account, api: "https://api.example"
  });
  assert.throws(() => parseCliArgs(["fees", "deliver", "--token", account]), /only supports/i);
  assert.throws(() => parseCliArgs([
    "fees", "prepare", "--token", account, "--private-key", "0xsecret"
  ]), /unsupported option/i);
});

const preparation = (() => {
  const request = buildV4LaunchRequest({
    name: "CLI Test", symbol: "CLITEST", launcher: account, userSalt: "0x1234"
  });
  const factory = "0x2222222222222222222222222222222222222222";
  return {
    version: "v4", chainId: 4663, factory,
    request: serializeV4LaunchRequest(request),
    requestDigest: launchRequestDigest(request),
    predictedTokenAddress: "0x0333333333333333333333333333333333333de6",
    transaction: { to: factory, data: encodeV4LaunchCalldata(request), value: "0x0" }
  };
})();

test("verify command returns stable public preparation identifiers", () => {
  assert.deepEqual(verifyPreparationDocument(preparation), {
    valid: true,
    chainId: 4663,
    factory: preparation.factory,
    launcher: account,
    requestDigest: preparation.requestDigest,
    predictedTokenAddress: preparation.predictedTokenAddress
  });
});

test("simulate command estimates and calls exact verified unsigned calldata", async () => {
  const calls = [];
  const result = await simulatePreparation(preparation, {
    client: {
      getChainId: async () => 4663,
      estimateGas: async (transaction) => { calls.push(["estimate", transaction]); return 2_800_000n; },
      call: async (transaction) => { calls.push(["call", transaction]); return { data: "0x" }; }
    }
  });
  assert.equal(result.simulated, true);
  assert.equal(result.gasEstimate, "2800000");
  assert.equal(calls.length, 2);
  for (const [, transaction] of calls) {
    assert.equal(transaction.account, account);
    assert.equal(transaction.to, preparation.factory);
    assert.equal(transaction.data, preparation.transaction.data);
    assert.equal(transaction.value, 0n);
  }
});

test("simulate command rejects an RPC connected to the wrong chain", async () => {
  await assert.rejects(() => simulatePreparation(preparation, {
    client: {
      getChainId: async () => 1,
      estimateGas: async () => { throw new Error("must not estimate"); },
      call: async () => { throw new Error("must not call"); }
    }
  }), /expected chain 4663.*received 1/i);
});

test("status command distinguishes indexed tokens from a 404", async () => {
  assert.deepEqual(await launchStatus(account, {
    client: { getToken: async () => ({ contract: account, sym: "TEST", launchId: 7 }) }
  }), { indexed: true, token: account, symbol: "TEST", launchId: 7 });
  assert.deepEqual(await launchStatus(account, {
    client: { getToken: async () => { const error = new Error("not found"); error.status = 404; throw error; } }
  }), { indexed: false, token: account });
});

const feePreparation = buildV4FeeDeliveryPreparation({
  protocolVersion: "v4",
  chainId: 4663,
  contract: "0x04d5D8a61DA0b6548B136412843aDBA55EbeaDE6",
  sym: "DEGEN",
  poolId: `0x${"4".repeat(64)}`,
  hook: "0x3333333333333333333333333333333333333333",
  lpLocker: "0x4444444444444444444444444444444444444444",
  feeLocker: "0x5555555555555555555555555555555555555555",
  beneficiary: account,
  feesWeth: { beneficiaryAccrued: "900", beneficiaryCredited: "600" },
  beneficiaryAccount: { claimable: "600", paid: "1200" }
});

test("fee inspection reports scoped earnings without calldata", () => {
  const result = inspectFeeDeliveryPreparation(feePreparation);
  assert.deepEqual(result.earnings, feePreparation.earnings);
  assert.equal(result.token, feePreparation.token);
  assert.equal(result.beneficiary, account);
  assert.deepEqual(result.steps.map((step) => step.id), ["collect", "flush", "claim"]);
  assert.equal("transaction" in result.steps[0], false);
});

test("fee preparation verifies the unsigned three-step bundle", async () => {
  const result = await prepareFeeDelivery(feePreparation.token, {
    client: { getFeeDeliveryPreparation: async () => feePreparation }
  });
  assert.equal(result.version, "v4-fee-delivery");
  assert.equal(result.steps.length, 3);
  assert.equal(result.steps.every((step) => step.transaction.value === "0x0"), true);
});
