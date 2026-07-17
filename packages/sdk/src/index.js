import { encodeAbiParameters, encodeFunctionData, keccak256 } from "viem";

export const ZERO_BYTES32 = `0x${"0".repeat(64)}`;

const ADDRESS = /^0x[0-9a-fA-F]{40}$/;
const BYTES32 = /^0x[0-9a-fA-F]{64}$/;
const ROBINHOOD_CHAIN_ID = 4663;
const ROBINHOOD_WETH = "0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73";

export const V4_LAUNCH_REQUEST = {
  name: "request",
  type: "tuple",
  components: [
    { name: "name", type: "string" },
    { name: "symbol", type: "string" },
    { name: "contractURI", type: "string" },
    { name: "imageURI", type: "string" },
    { name: "launcher", type: "address" },
    { name: "tokenAdmin", type: "address" },
    { name: "feeAdmin", type: "address" },
    { name: "beneficiary", type: "address" },
    { name: "templateId", type: "uint256" },
    { name: "userSalt", type: "bytes32" }
  ]
};

export const V4_FACTORY_ABI = [{
  type: "function",
  name: "launch",
  stateMutability: "nonpayable",
  inputs: [V4_LAUNCH_REQUEST],
  outputs: []
}];

export const V4_FEE_DELIVERY_ABIS = {
  collect: [{
    type: "function", name: "collectRewards", stateMutability: "nonpayable",
    inputs: [{ name: "token", type: "address" }],
    outputs: [{ name: "tokenFees", type: "uint256" }, { name: "wethFees", type: "uint256" }]
  }],
  flush: [{
    type: "function", name: "flushPoolFees", stateMutability: "nonpayable",
    inputs: [{ name: "poolId", type: "bytes32" }, { name: "beneficiary", type: "address" }],
    outputs: [{ name: "protocolPaid", type: "uint256" }, { name: "beneficiaryStored", type: "uint256" }]
  }],
  claim: [{
    type: "function", name: "claimFor", stateMutability: "nonpayable",
    inputs: [{ name: "beneficiary", type: "address" }],
    outputs: [{ name: "amount", type: "uint256" }]
  }]
};

const canonicalSalt = (value = ZERO_BYTES32) => {
  const hex = String(value).replace(/^0x/i, "");
  if (!/^[0-9a-fA-F]*$/.test(hex) || hex.length > 64) throw new Error("Invalid v4 user salt");
  return `0x${hex.padStart(64, "0").toLowerCase()}`;
};

const role = (value, fallback, label) => {
  const address = value || fallback;
  if (!ADDRESS.test(address || "")) throw new Error(`${label} must be a valid address`);
  return address;
};

export function buildV4LaunchRequest({
  name,
  symbol,
  launcher,
  tokenAdmin = launcher,
  feeAdmin = launcher,
  beneficiary = launcher,
  description = "",
  website = "",
  x = "",
  telegram = "",
  contractURI,
  image = "",
  imageURI = image,
  templateId = 2,
  userSalt = ZERO_BYTES32
} = {}) {
  const canonicalName = String(name || "").trim();
  const canonicalSymbol = String(symbol || "").trim().toUpperCase();
  if (!canonicalName || canonicalName.length > 32) throw new Error("name must contain 1 to 32 characters");
  if (!canonicalSymbol || canonicalSymbol.length > 10) throw new Error("symbol must contain 1 to 10 characters");
  const canonicalTemplate = BigInt(templateId);
  if (canonicalTemplate < 1n || canonicalTemplate > BigInt(Number.MAX_SAFE_INTEGER)) {
    throw new Error("templateId must be a positive safe integer");
  }
  return {
    name: canonicalName,
    symbol: canonicalSymbol,
    contractURI: contractURI ?? JSON.stringify({ description, website, x, telegram }),
    imageURI: String(imageURI || ""),
    launcher: role(launcher, "", "launcher"),
    tokenAdmin: role(tokenAdmin, launcher, "tokenAdmin"),
    feeAdmin: role(feeAdmin, launcher, "feeAdmin"),
    beneficiary: role(beneficiary, launcher, "beneficiary"),
    templateId: canonicalTemplate,
    userSalt: canonicalSalt(userSalt)
  };
}

export function serializeV4LaunchRequest(request) {
  const canonical = buildV4LaunchRequest(request);
  return { ...canonical, templateId: canonical.templateId.toString() };
}

export function launchRequestDigest(request) {
  const canonical = buildV4LaunchRequest(request);
  return keccak256(encodeAbiParameters([V4_LAUNCH_REQUEST], [canonical]));
}

export function encodeV4LaunchCalldata(request) {
  const canonical = buildV4LaunchRequest(request);
  return encodeFunctionData({ abi: V4_FACTORY_ABI, functionName: "launch", args: [canonical] });
}

export function verifyLaunchPreparation(preparation) {
  if (!preparation || preparation.version !== "v4") throw new Error("unsupported launch preparation version");
  if (Number(preparation.chainId) !== ROBINHOOD_CHAIN_ID) {
    throw new Error(`launch preparation must target Robinhood Chain ${ROBINHOOD_CHAIN_ID}`);
  }
  if (!ADDRESS.test(preparation.factory || "")) throw new Error("preparation factory is invalid");
  if (!ADDRESS.test(preparation.predictedTokenAddress || "") || !preparation.predictedTokenAddress.toLowerCase().endsWith("de6")) {
    throw new Error("predicted token address does not satisfy the DegenHood vanity rule");
  }
  if (BigInt(preparation.predictedTokenAddress) >= BigInt(ROBINHOOD_WETH)) {
    throw new Error("predicted token address does not satisfy Robinhood WETH pool ordering");
  }
  const request = buildV4LaunchRequest(preparation.request);
  if (launchRequestDigest(request).toLowerCase() !== String(preparation.requestDigest || "").toLowerCase()) {
    throw new Error("launch preparation digest does not match the request");
  }
  if (String(preparation.transaction?.to || "").toLowerCase() !== preparation.factory.toLowerCase()) {
    throw new Error("launch preparation transaction target does not match the factory");
  }
  if (String(preparation.transaction?.value || "0x0").toLowerCase() !== "0x0") {
    throw new Error("launch preparation transaction must not transfer value");
  }
  if (encodeV4LaunchCalldata(request).toLowerCase() !== String(preparation.transaction?.data || "").toLowerCase()) {
    throw new Error("launch preparation calldata does not match the request");
  }
  return { ...preparation, request };
}

const feeAddress = (value, label) => {
  if (!ADDRESS.test(value || "") || BigInt(value) === 0n) throw new Error(`${label} must be a valid nonzero address`);
  return value;
};

const weiString = (value = "0", label = "amount") => {
  try {
    const amount = BigInt(value);
    if (amount < 0n) throw new Error();
    return amount.toString();
  } catch {
    throw new Error(`${label} must be a nonnegative integer`);
  }
};

const feeDeliveryCore = ({ token, poolId, beneficiary, hook, lpLocker, feeLocker }) => {
  if (!BYTES32.test(poolId || "")) throw new Error("poolId must be bytes32");
  return {
    token: feeAddress(token, "token"),
    poolId: poolId.toLowerCase(),
    beneficiary: feeAddress(beneficiary, "beneficiary"),
    destinations: {
      hook: feeAddress(hook, "hook"),
      lpLocker: feeAddress(lpLocker, "LP locker"),
      feeLocker: feeAddress(feeLocker, "FeeLocker")
    }
  };
};

const feeDeliverySteps = ({ token, poolId, beneficiary, destinations }) => [
  {
    id: "collect",
    label: "Collect LP fees",
    transaction: {
      to: destinations.lpLocker,
      data: encodeFunctionData({ abi: V4_FEE_DELIVERY_ABIS.collect, functionName: "collectRewards", args: [token] }),
      value: "0x0"
    }
  },
  {
    id: "flush",
    label: "Flush creator fees",
    transaction: {
      to: destinations.hook,
      data: encodeFunctionData({ abi: V4_FEE_DELIVERY_ABIS.flush, functionName: "flushPoolFees", args: [poolId, beneficiary] }),
      value: "0x0"
    }
  },
  {
    id: "claim",
    label: "Pay beneficiary",
    transaction: {
      to: destinations.feeLocker,
      data: encodeFunctionData({ abi: V4_FEE_DELIVERY_ABIS.claim, functionName: "claimFor", args: [beneficiary] }),
      value: "0x0"
    }
  }
];

export function buildV4FeeDeliveryPreparation(record = {}) {
  if (record.protocolVersion !== "v4") throw new Error("fee delivery requires an indexed v4 token");
  if (Number(record.chainId) !== ROBINHOOD_CHAIN_ID) throw new Error(`fee delivery requires Robinhood Chain ${ROBINHOOD_CHAIN_ID}`);
  const core = feeDeliveryCore({
    token: record.contract,
    poolId: record.poolId,
    beneficiary: record.roles?.beneficiary || record.beneficiary,
    hook: record.hook,
    lpLocker: record.lpLocker,
    feeLocker: record.feeLocker
  });
  const lifetimeAccruedWei = weiString(record.feesWeth?.beneficiaryAccrued, "lifetime accrued WETH");
  const creditedWei = weiString(record.feesWeth?.beneficiaryCredited, "credited WETH");
  const pending = BigInt(lifetimeAccruedWei) - BigInt(creditedWei);
  const earnings = {
    lifetimeAccruedWei,
    pendingDeliveryWei: (pending > 0n ? pending : 0n).toString(),
    claimableWei: weiString(record.beneficiaryAccount?.claimable, "claimable WETH"),
    paidWei: weiString(record.beneficiaryAccount?.paid, "paid WETH"),
    scope: "fee-locker-beneficiary"
  };
  return {
    version: "v4-fee-delivery",
    chainId: ROBINHOOD_CHAIN_ID,
    token: core.token,
    symbol: String(record.sym || record.symbol || "").toUpperCase(),
    poolId: core.poolId,
    beneficiary: core.beneficiary,
    destinations: core.destinations,
    earnings,
    steps: feeDeliverySteps(core)
  };
}

export function verifyV4FeeDeliveryPreparation(preparation) {
  if (!preparation || preparation.version !== "v4-fee-delivery") throw new Error("unsupported fee delivery preparation version");
  if (Number(preparation.chainId) !== ROBINHOOD_CHAIN_ID) throw new Error(`fee delivery must target Robinhood Chain ${ROBINHOOD_CHAIN_ID}`);
  const core = feeDeliveryCore({
    token: preparation.token,
    poolId: preparation.poolId,
    beneficiary: preparation.beneficiary,
    ...preparation.destinations
  });
  const expected = feeDeliverySteps(core);
  if (!Array.isArray(preparation.steps) || preparation.steps.length !== expected.length) {
    throw new Error("fee delivery preparation must contain collect, flush and claim steps");
  }
  expected.forEach((step, index) => {
    const supplied = preparation.steps[index];
    if (supplied?.id !== step.id) throw new Error(`${step.id} step is missing or out of order`);
    if (String(supplied.transaction?.to || "").toLowerCase() !== step.transaction.to.toLowerCase()) {
      throw new Error(`${step.id} target does not match indexed protocol destination`);
    }
    if (String(supplied.transaction?.value || "0x0").toLowerCase() !== "0x0") {
      throw new Error(`${step.id} transaction must not transfer value`);
    }
    if (String(supplied.transaction?.data || "").toLowerCase() !== step.transaction.data.toLowerCase()) {
      throw new Error(`${step.id} calldata does not match indexed token state`);
    }
  });
  const earnings = {
    lifetimeAccruedWei: weiString(preparation.earnings?.lifetimeAccruedWei, "lifetime accrued WETH"),
    pendingDeliveryWei: weiString(preparation.earnings?.pendingDeliveryWei, "pending delivery WETH"),
    claimableWei: weiString(preparation.earnings?.claimableWei, "claimable WETH"),
    paidWei: weiString(preparation.earnings?.paidWei, "paid WETH"),
    scope: preparation.earnings?.scope
  };
  if (earnings.scope !== "fee-locker-beneficiary") throw new Error("fee delivery earnings scope is invalid");
  return { ...preparation, ...core, earnings, steps: expected };
}

const bearer = (value) => value ? { authorization: `Bearer ${value}` } : {};

export function createDegenHoodClient({ baseUrl, accessToken = "", fetch: request = globalThis.fetch } = {}) {
  if (!baseUrl) throw new Error("baseUrl is required");
  if (typeof request !== "function") throw new Error("fetch implementation is required");
  const root = String(baseUrl).replace(/\/$/, "");

  const send = async (path, { method = "GET", body, signal, token, authenticated = false } = {}) => {
    const credential = authenticated
      ? token || (typeof accessToken === "function" ? await accessToken() : accessToken)
      : "";
    const response = await request(`${root}${path}`, {
      method,
      headers: { ...(body === undefined ? {} : { "content-type": "application/json" }), ...bearer(credential) },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
      signal
    });
    const payload = await response.json().catch(() => ({}));
    if (!response.ok) {
      const error = new Error(payload.error || `DegenHood API request failed (${response.status})`);
      error.status = response.status;
      error.retryAfter = response.headers.get("retry-after");
      throw error;
    }
    return payload;
  };

  return {
    requestWalletChallenge({ wallet } = {}, options) {
      if (!ADDRESS.test(wallet || "")) throw new Error("valid wallet address is required");
      return send("/api/v1/auth/challenges", {
        ...options,
        method: "POST",
        body: { wallet, scope: "launch:prepare" }
      });
    },
    createWalletSession({ challengeId, signature } = {}, options) {
      if (typeof challengeId !== "string" || !challengeId) throw new Error("challengeId is required");
      if (typeof signature !== "string" || !/^0x[0-9a-fA-F]+$/.test(signature)) {
        throw new Error("hex message signature is required");
      }
      return send("/api/v1/auth/sessions", {
        ...options,
        method: "POST",
        body: { challengeId, signature }
      });
    },
    prepareLaunch(input, options) {
      const requestBody = serializeV4LaunchRequest(buildV4LaunchRequest({ ...input, userSalt: ZERO_BYTES32 }));
      delete requestBody.userSalt;
      return send("/api/v1/launch-preparations", {
        ...options, method: "POST", body: requestBody, authenticated: true
      });
    },
    getHealth(options) {
      return send("/health", options);
    },
    getToken(key, options) {
      if (!key) throw new Error("token key is required");
      return send(`/api/token/${encodeURIComponent(key)}`, options);
    },
    async getFeeDeliveryPreparation(key, options) {
      if (!key) throw new Error("token key is required");
      const record = await send(`/api/token/${encodeURIComponent(key)}`, options);
      return buildV4FeeDeliveryPreparation(record);
    },
    verifyPreparation: verifyLaunchPreparation,
    verifyFeeDeliveryPreparation: verifyV4FeeDeliveryPreparation
  };
}

export function assertV4LaunchRequest(request) {
  const canonical = buildV4LaunchRequest(request);
  if (!BYTES32.test(canonical.userSalt)) throw new Error("userSalt must be bytes32");
  return canonical;
}
