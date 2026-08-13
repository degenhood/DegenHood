import test from "node:test";
import assert from "node:assert/strict";
import { decodeFunctionData } from "viem";
import * as sdk from "../src/index.js";
import {
  ZERO_BYTES32,
  buildV4LaunchRequest,
  createDegenHoodClient,
  encodeV4LaunchCalldata,
  launchRequestDigest,
  serializeV4LaunchRequest,
  verifyLaunchPreparation
} from "../src/index.js";

const launcher = "0x1111111111111111111111111111111111111111";
const factory = "0x2222222222222222222222222222222222222222";
const hub = "0x6666666666666666666666666666666666666666";
const domainId = `0x${"8".repeat(64)}`;
const module = "0x7777777777777777777777777777777777777777";
const tokenDeployer = "0x8888888888888888888888888888888888888888";
const predictedToken = "0x0333333333333333333333333333333333333de6";
const spy = "0x117cc2133c37B721F49dE2A7a74833232B3B4C0C";
const spyOnlyPredictedToken = `0x10${"0".repeat(35)}de6`;

test("LaunchHub draft canonicalizes the full commitment without a prediction", () => {
  assert.equal(typeof sdk.buildHubLaunchDraft, "function", "buildHubLaunchDraft is missing");
  const draft = sdk.buildHubLaunchDraft({
    domainId,
    templateId: 4,
    version: 1,
    name: "  Spy Hood  ",
    symbol: "spyhood",
    launcher,
    description: "SPY launch",
    website: "https://degenhood.fun",
    userSalt: "0x01",
  });

  assert.equal(draft.name, "Spy Hood");
  assert.equal(draft.symbol, "SPYHOOD");
  assert.equal(draft.templateId, 4n);
  assert.equal(draft.version, 1);
  assert.equal(draft.tokenAdmin, launcher);
  assert.equal(draft.feeAdmin, launcher);
  assert.equal(draft.beneficiary, launcher);
  assert.equal(draft.userSalt, `0x${"0".repeat(62)}01`);
  assert.equal(draft.launchData, "0x");
  assert.equal(draft.contractURI, JSON.stringify({
    description: "SPY launch",
    website: "https://degenhood.fun",
    x: "",
    telegram: "",
  }));
  assert.match(sdk.hubLaunchCommitment(draft), /^0x[0-9a-f]{64}$/);
  assert.notEqual(
    sdk.hubLaunchCommitment({ ...draft, beneficiary: factory }),
    sdk.hubLaunchCommitment(draft),
  );
  assert.throws(() => sdk.buildHubLaunchDraft({
    ...draft, domainId: sdk.ZERO_BYTES32
  }), /domainId/i);
});

test("LaunchHub calldata binds the prediction and every request field", () => {
  const draft = sdk.buildHubLaunchDraft({
    domainId,
    templateId: 2,
    version: 1,
    name: "Degen Hub",
    symbol: "HUB",
    launcher,
    userSalt: "0x1234",
  });
  const request = sdk.buildHubLaunchRequest({ ...draft, predictedToken });
  const decoded = decodeFunctionData({
    abi: sdk.HUB_LAUNCH_ABI,
    data: sdk.encodeHubLaunchCalldata(request),
  });

  assert.equal(decoded.functionName, "launch");
  assert.equal(decoded.args[0].domainId, domainId);
  assert.equal(decoded.args[0].templateId, 2n);
  assert.equal(decoded.args[0].version, 1);
  assert.equal(decoded.args[0].predictedToken, predictedToken);
  assert.equal(decoded.args[0].launchData, "0x");
});

test("LaunchHub preparation is one verified zero-value direct Hub call", () => {
  const request = sdk.buildHubLaunchRequest({
    ...sdk.buildHubLaunchDraft({
      domainId,
      templateId: 3,
      version: 1,
      name: "Degen Three",
      symbol: "D3",
      launcher,
    }),
    predictedToken,
  });
  const preparation = {
    version: "launchhub-launch-v1",
    chainId: 4663,
    launchHub: hub,
    request: sdk.serializeHubLaunchRequest(request),
    commitment: sdk.hubLaunchCommitment(request),
    predictedTokenAddress: predictedToken,
    activatedTemplate: {
      status: "active",
      module,
      tokenDeployer,
    },
    prediction: {
      module,
      tokenDeployer,
    },
    transaction: {
      to: hub,
      data: sdk.encodeHubLaunchCalldata(request),
      value: "0x0",
    },
  };

  const verified = sdk.verifyHubLaunchPreparation(preparation);
  assert.equal(verified.request.predictedToken, predictedToken);
  assert.equal(verified.request.templateId, 3n);
  assert.equal(verified.transaction.to, hub);

  assert.throws(
    () => sdk.verifyHubLaunchPreparation({
      ...preparation,
      activatedTemplate: { ...preparation.activatedTemplate, status: "deprecated" },
    }),
    /active template/i,
  );
  assert.throws(
    () => sdk.verifyHubLaunchPreparation({
      ...preparation,
      prediction: { ...preparation.prediction, module: factory },
    }),
    /module/i,
  );
  assert.throws(
    () => sdk.verifyHubLaunchPreparation({
      ...preparation,
      transaction: { ...preparation.transaction, value: "0x1" },
    }),
    /zero-value/i,
  );
  assert.throws(
    () => sdk.verifyHubLaunchPreparation({
      ...preparation,
      request: { ...preparation.request, symbol: "DRIFT" },
    }),
    /commitment/i,
  );
});

test("LaunchHub preparation verifies canonical ordering against its explicit quote", () => {
  const request = sdk.buildHubLaunchRequest({
    ...sdk.buildHubLaunchDraft({
      domainId,
      templateId: 4,
      version: 3,
      name: "SPY Clone",
      symbol: "SPYCLONE",
      launcher,
    }),
    predictedToken: spyOnlyPredictedToken,
  });
  const preparation = {
    version: "launchhub-launch-v1",
    chainId: 4663,
    launchHub: hub,
    request: sdk.serializeHubLaunchRequest(request),
    commitment: sdk.hubLaunchCommitment(request),
    predictedTokenAddress: spyOnlyPredictedToken,
    activatedTemplate: { status: "active", module, tokenDeployer },
    prediction: { module, tokenDeployer, orderingBound: spy },
    transaction: {
      to: hub,
      data: sdk.encodeHubLaunchCalldata(request),
      value: "0x0",
    },
  };

  assert.equal(
    sdk.verifyHubLaunchPreparation(preparation).prediction.orderingBound,
    spy
  );
  assert.throws(
    () => sdk.verifyHubLaunchPreparation({
      ...preparation,
      prediction: { module, tokenDeployer }
    }),
    /pool ordering/i
  );
  assert.throws(
    () => sdk.verifyHubLaunchPreparation({
      ...preparation,
      prediction: {
        ...preparation.prediction,
        orderingBound: "0x0000000000000000000000000000000000000000"
      }
    }),
    /ordering bound/i
  );
});

test("canonical request normalises metadata, roles, template and salt", () => {
  const request = buildV4LaunchRequest({
    name: "  Degen Test  ", symbol: "test", launcher,
    description: "story", website: "https://degenhood.fun",
    templateId: 2, userSalt: "0x01"
  });
  assert.equal(request.name, "Degen Test");
  assert.equal(request.symbol, "TEST");
  assert.equal(request.tokenAdmin, launcher);
  assert.equal(request.feeAdmin, launcher);
  assert.equal(request.beneficiary, launcher);
  assert.equal(request.templateId, 2n);
  assert.equal(request.userSalt, `0x${"0".repeat(62)}01`);
  assert.equal(request.contractURI, JSON.stringify({
    description: "story", website: "https://degenhood.fun", x: "", telegram: ""
  }));
});

test("digest and calldata bind the exact canonical request", () => {
  const request = buildV4LaunchRequest({ name: "Degen Test", symbol: "TEST", launcher });
  const digest = launchRequestDigest(request);
  const data = encodeV4LaunchCalldata(request);
  assert.match(digest, /^0x[0-9a-f]{64}$/);
  assert.match(data, /^0x[0-9a-f]+$/);
  assert.notEqual(launchRequestDigest({ ...request, userSalt: `0x${"0".repeat(63)}1` }), digest);
  assert.ok(data.length > 10);
});

test("preparation verification rejects request or calldata drift", () => {
  const request = buildV4LaunchRequest({
    name: "Degen Test", symbol: "TEST", launcher, userSalt: "0x1234"
  });
  const preparation = {
    version: "v4",
    chainId: 4663,
    factory,
    request: serializeV4LaunchRequest(request),
    requestDigest: launchRequestDigest(request),
    predictedTokenAddress: "0x0333333333333333333333333333333333333de6",
    transaction: { to: factory, data: encodeV4LaunchCalldata(request), value: "0x0" }
  };
  assert.equal(verifyLaunchPreparation(preparation).request.userSalt, request.userSalt);
  assert.throws(() => verifyLaunchPreparation({
    ...preparation, transaction: { ...preparation.transaction, data: "0x1234" }
  }), /calldata/i);
  assert.throws(() => verifyLaunchPreparation({
    ...preparation, request: { ...preparation.request, symbol: "DRIFT" }
  }), /digest/i);
  assert.throws(() => verifyLaunchPreparation({
    ...preparation, predictedTokenAddress: "0xf333333333333333333333333333333333333de6"
  }), /pool ordering/i);
  assert.throws(() => verifyLaunchPreparation({ ...preparation, chainId: 1 }), /Robinhood Chain 4663/i);
});

test("HTTP client prepares a launch with bearer authentication", async () => {
  let observed;
  const client = createDegenHoodClient({
    baseUrl: "https://api.degenhood.fun",
    accessToken: "secret",
    fetch: async (url, options) => {
      observed = { url, options };
      return new Response(JSON.stringify({ ok: true }), {
        status: 200, headers: { "content-type": "application/json" }
      });
    }
  });
  assert.deepEqual(await client.prepareLaunch({ name: "Degen Test", symbol: "TEST", launcher }), { ok: true });
  assert.equal(observed.url, "https://api.degenhood.fun/api/v1/launch-preparations");
  assert.equal(observed.options.headers.authorization, "Bearer secret");
  assert.equal(JSON.parse(observed.options.body).userSalt, undefined);
});

test("HTTP client transports wallet challenges and externally produced signatures without signing", async () => {
  const observed = [];
  const responses = [
    { challengeId: "challenge-1", wallet: launcher, message: "message to sign", scope: "launch:prepare" },
    { accessToken: "session-token", tokenType: "Bearer", expiresIn: 900, wallet: launcher, scope: "launch:prepare" }
  ];
  const client = createDegenHoodClient({
    baseUrl: "https://api.degenhood.fun",
    accessToken: "must-not-be-sent",
    fetch: async (url, options) => {
      observed.push({ url, options });
      return new Response(JSON.stringify(responses.shift()), {
        status: 201, headers: { "content-type": "application/json" }
      });
    }
  });

  assert.equal((await client.requestWalletChallenge({ wallet: launcher })).message, "message to sign");
  assert.equal((await client.createWalletSession({
    challengeId: "challenge-1",
    signature: `0x${"11".repeat(65)}`
  })).accessToken, "session-token");
  assert.deepEqual(observed.map(({ url, options }) => ({
    url,
    method: options.method,
    body: JSON.parse(options.body),
    authorization: options.headers.authorization
  })), [
    {
      url: "https://api.degenhood.fun/api/v1/auth/challenges",
      method: "POST",
      body: { wallet: launcher, scope: "launch:prepare" },
      authorization: undefined
    },
    {
      url: "https://api.degenhood.fun/api/v1/auth/sessions",
      method: "POST",
      body: { challengeId: "challenge-1", signature: `0x${"11".repeat(65)}` },
      authorization: undefined
    }
  ]);
  assert.equal("signMessage" in client, false);
});

test("HTTP client exposes read-only health and indexed-token lookups", async () => {
  const observed = [];
  const client = createDegenHoodClient({
    baseUrl: "https://api.degenhood.fun/",
    fetch: async (url, options) => {
      observed.push({ url, options });
      return new Response(JSON.stringify(url.endsWith("/health")
        ? { ok: true }
        : { contract: launcher, sym: "TEST" }), {
        status: 200, headers: { "content-type": "application/json" }
      });
    }
  });
  assert.deepEqual(await client.getHealth(), { ok: true });
  assert.deepEqual(await client.getToken(launcher), { contract: launcher, sym: "TEST" });
  assert.deepEqual(observed.map((entry) => [entry.url, entry.options.method]), [
    ["https://api.degenhood.fun/health", "GET"],
    [`https://api.degenhood.fun/api/token/${launcher}`, "GET"]
  ]);
  assert.equal(observed[0].options.headers.authorization, undefined);
});

test("HTTP client preserves status and retry hints on JSON errors", async () => {
  const client = createDegenHoodClient({
    baseUrl: "https://api.degenhood.fun",
    fetch: async () => new Response(JSON.stringify({ error: "queue full" }), {
      status: 503,
      headers: { "content-type": "application/json", "retry-after": "2" }
    })
  });
  await assert.rejects(() => client.getHealth(), (error) => {
    assert.equal(error.message, "queue full");
    assert.equal(error.status, 503);
    assert.equal(error.retryAfter, "2");
    return true;
  });
});

test("zero salt is exported for callers preparing a pre-mining request", () => {
  assert.equal(ZERO_BYTES32, `0x${"0".repeat(64)}`);
});

const feeToken = {
  protocolVersion: "v4",
  chainId: 4663,
  contract: "0x04d5D8a61DA0b6548B136412843aDBA55EbeaDE6",
  sym: "DEGEN",
  poolId: `0x${"4".repeat(64)}`,
  hook: "0x3333333333333333333333333333333333333333",
  lpLocker: "0x4444444444444444444444444444444444444444",
  feeLocker: "0x5555555555555555555555555555555555555555",
  beneficiary: launcher,
  feesWeth: { beneficiaryAccrued: "900", beneficiaryCredited: "600" },
  beneficiaryAccount: { claimable: "600", paid: "1200" }
};

test("v4 fee delivery preparation canonicalizes three zero-value permissionless calls", () => {
  const preparation = sdk.buildV4FeeDeliveryPreparation(feeToken);
  assert.equal(preparation.version, "v4-fee-delivery");
  assert.equal(preparation.chainId, 4663);
  assert.deepEqual(preparation.earnings, {
    lifetimeAccruedWei: "900",
    pendingDeliveryWei: "300",
    claimableWei: "600",
    paidWei: "1200",
    scope: "fee-locker-beneficiary"
  });
  assert.deepEqual(preparation.steps.map((step) => [step.id, step.transaction.to, step.transaction.value]), [
    ["collect", feeToken.lpLocker, "0x0"],
    ["flush", feeToken.hook, "0x0"],
    ["claim", feeToken.feeLocker, "0x0"]
  ]);
  assert.deepEqual(preparation.steps.map((step) => decodeFunctionData({
    abi: sdk.V4_FEE_DELIVERY_ABIS[step.id], data: step.transaction.data
  }).functionName), ["collectRewards", "flushPoolFees", "claimFor"]);
  assert.equal(sdk.verifyV4FeeDeliveryPreparation(preparation).beneficiary, launcher);
});

test("v4 fee delivery preparation rejects incomplete records and calldata drift", () => {
  assert.throws(() => sdk.buildV4FeeDeliveryPreparation({ ...feeToken, protocolVersion: "v3" }), /v4 token/i);
  assert.throws(() => sdk.buildV4FeeDeliveryPreparation({ ...feeToken, poolId: "0x1234" }), /poolId/i);
  const preparation = sdk.buildV4FeeDeliveryPreparation(feeToken);
  assert.throws(() => sdk.verifyV4FeeDeliveryPreparation({
    ...preparation,
    steps: preparation.steps.map((step, index) => index === 1
      ? { ...step, transaction: { ...step.transaction, data: "0x1234" } }
      : step)
  }), /flush calldata/i);
});

test("HTTP client builds verified fee delivery from the indexed token record", async () => {
  const client = createDegenHoodClient({
    baseUrl: "https://api.degenhood.fun",
    fetch: async () => new Response(JSON.stringify(feeToken), {
      status: 200, headers: { "content-type": "application/json" }
    })
  });
  const preparation = await client.getFeeDeliveryPreparation(feeToken.contract);
  assert.equal(preparation.token, feeToken.contract);
  assert.equal(preparation.symbol, "DEGEN");
  assert.equal(preparation.steps.length, 3);
  assert.equal(client.verifyFeeDeliveryPreparation(preparation).version, "v4-fee-delivery");
});

const hubFeeToken = {
  protocolVersion: "launchhub-v1",
  chainId: 4663,
  contract: "0x04d5D8a61DA0b6548B136412843aDBA55EbeaDE6",
  sym: "DEGEN",
  beneficiary: launcher,
  launchHub: "0x6666666666666666666666666666666666666666",
  launchRecord: {
    token: "0x04d5D8a61DA0b6548B136412843aDBA55EbeaDE6",
    module: "0x7777777777777777777777777777777777777777",
    domainId: `0x${"8".repeat(64)}`,
    templateId: "2",
    version: "1"
  },
  activatedTemplate: {
    status: "active",
    module: "0x7777777777777777777777777777777777777777",
    lpLocker: "0x8888888888888888888888888888888888888888"
  }
};

test("LaunchHub fee claim preparation contains exactly one destination-bound transaction", () => {
  const preparation = sdk.buildHubFeeClaimPreparation(hubFeeToken);
  assert.equal(preparation.version, "launchhub-fee-claim-v1");
  assert.equal(preparation.chainId, 4663);
  assert.equal(preparation.token, hubFeeToken.contract);
  assert.equal(preparation.beneficiary, launcher);
  assert.equal(preparation.transaction.to, hubFeeToken.activatedTemplate.lpLocker);
  assert.equal(preparation.transaction.value, "0x0");
  assert.equal(decodeFunctionData({
    abi: sdk.HUB_FEE_CLAIMER_ABI,
    data: preparation.transaction.data
  }).functionName, "claimFees");
  assert.deepEqual(
    decodeFunctionData({
      abi: sdk.HUB_FEE_CLAIMER_ABI,
      data: preparation.transaction.data
    }).args,
    [hubFeeToken.contract]
  );
  assert.equal(sdk.verifyHubFeeClaimPreparation(preparation).template.status, "active");
});

test("LaunchHub fee claim fails closed on untrusted or inconsistent indexed template state", () => {
  assert.throws(
    () => sdk.buildHubFeeClaimPreparation({ ...hubFeeToken, protocolVersion: "v4" }),
    /indexed LaunchHub token/i
  );
  assert.throws(
    () => sdk.buildHubFeeClaimPreparation({
      ...hubFeeToken,
      activatedTemplate: { ...hubFeeToken.activatedTemplate, status: "pending" }
    }),
    /activated/i
  );
  assert.throws(
    () => sdk.buildHubFeeClaimPreparation({
      ...hubFeeToken,
      launchRecord: {
        ...hubFeeToken.launchRecord,
        module: "0x9999999999999999999999999999999999999999"
      }
    }),
    /module/i
  );
  assert.throws(
    () => sdk.buildHubFeeClaimPreparation({
      ...hubFeeToken,
      activatedTemplate: { ...hubFeeToken.activatedTemplate, lpLocker: undefined },
      lpLocker: "0x9999999999999999999999999999999999999999"
    }),
    /LP locker/i
  );

  const preparation = sdk.buildHubFeeClaimPreparation(hubFeeToken);
  assert.throws(
    () => sdk.verifyHubFeeClaimPreparation({
      ...preparation,
      transaction: {
        ...preparation.transaction,
        to: "0x9999999999999999999999999999999999999999"
      }
    }),
    /target/i
  );
  assert.throws(
    () => sdk.verifyHubFeeClaimPreparation({
      ...preparation,
      transaction: { ...preparation.transaction, data: "0x1234" }
    }),
    /calldata/i
  );
  assert.throws(
    () => sdk.verifyHubFeeClaimPreparation({
      ...preparation,
      transaction: { ...preparation.transaction, value: "0x1" }
    }),
    /transfer value/i
  );
});

test("deprecated LaunchHub templates remain claimable for tokens launched while activated", () => {
  const preparation = sdk.buildHubFeeClaimPreparation({
    ...hubFeeToken,
    activatedTemplate: { ...hubFeeToken.activatedTemplate, status: "deprecated" }
  });
  assert.equal(preparation.template.status, "deprecated");
  assert.equal(preparation.transaction.to, hubFeeToken.activatedTemplate.lpLocker);
  assert.equal(sdk.verifyHubFeeClaimPreparation(preparation).template.status, "deprecated");
});

test("V1 and V2 fee claims retain their exact source Hub, template version, and locker", () => {
  const v1 = sdk.buildHubFeeClaimPreparation(hubFeeToken);
  const v2Token = {
    ...hubFeeToken,
    launchHub: "0x9999999999999999999999999999999999999999",
    launchRecord: {
      ...hubFeeToken.launchRecord,
      version: "2",
      module: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    },
    activatedTemplate: {
      ...hubFeeToken.activatedTemplate,
      module: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      lpLocker: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    }
  };
  const v2 = sdk.buildHubFeeClaimPreparation(v2Token);

  assert.equal(v1.launchHub, hubFeeToken.launchHub);
  assert.equal(v1.launchRecord.version, "1");
  assert.equal(v1.transaction.to, hubFeeToken.activatedTemplate.lpLocker);
  assert.equal(v2.launchHub, v2Token.launchHub);
  assert.equal(v2.launchRecord.version, "2");
  assert.equal(v2.transaction.to, v2Token.activatedTemplate.lpLocker);
});

test("HTTP client selects the one-transaction LaunchHub claim from indexed provenance", async () => {
  const client = createDegenHoodClient({
    baseUrl: "https://api.degenhood.fun",
    fetch: async () => new Response(JSON.stringify(hubFeeToken), {
      status: 200, headers: { "content-type": "application/json" }
    })
  });
  const preparation = await client.getFeeDeliveryPreparation(hubFeeToken.contract);
  assert.equal(preparation.version, "launchhub-fee-claim-v1");
  assert.equal(preparation.transaction.to, hubFeeToken.activatedTemplate.lpLocker);
  assert.equal(client.verifyFeeDeliveryPreparation(preparation).token, hubFeeToken.contract);
});
