# @degenhood/sdk

Shared, non-custodial request tooling for DegenHood v4 launches on Robinhood Chain.

> **Compatibility:** The published `0.1.x` line is legacy v4-factory tooling. It does not implement
> the current production LaunchHub integration. Do not use it to construct a new production launch.
> See [`COMPATIBILITY.md`](../../COMPATIBILITY.md).

## Install

```sh
npm install @degenhood/sdk@0.1.0-canary.0
```

Version `0.1.0-canary.0` is a controlled early-access canary prerelease published under the
`canary` dist-tag. The command above becomes
available only after the DegenHood operator publishes the reviewed package.

Start from
[`examples/developer/prepare-launch.ts`](../../examples/developer/prepare-launch.ts) and
[`examples/developer/token.example.json`](../../examples/developer/token.example.json). The
quickstart injects the creator's existing wallet client, obtains a 15-minute preparation-only
session, verifies the returned calldata, and runs read-only gas estimation and call simulation.
It does not store a private key, sign a transaction, or broadcast.

## Usage

```js
import { createDegenHoodClient, verifyLaunchPreparation } from "@degenhood/sdk";

const client = createDegenHoodClient({
  baseUrl: "https://api.degenhood.fun",
  accessToken: async () => getPrivyAccessToken()
});

const preparation = await client.prepareLaunch({
  name: "Example Hood",
  symbol: "EXAMPLE",
  launcher: account,
  tokenAdmin: account,
  feeAdmin: account,
  beneficiary: account,
  description: "The creator story.",
  templateId: 2
});

verifyLaunchPreparation(preparation);
// preparation.transaction is unsigned. The launcher signs and pays gas.
```

For an allowlisted headless creator, the SDK transports the challenge and an externally produced
EIP-191 signature but never signs it:

```js
const publicClient = createDegenHoodClient({ baseUrl: "https://api.degenhood.fun" });
const challenge = await publicClient.requestWalletChallenge({ wallet: account });

// This signing operation belongs to your wallet client, outside @degenhood/sdk.
const signature = await walletClient.signMessage({ message: challenge.message });
const session = await publicClient.createWalletSession({
  challengeId: challenge.challengeId,
  signature
});

const sessionClient = createDegenHoodClient({
  baseUrl: "https://api.degenhood.fun",
  accessToken: session.accessToken
});
```

The session lasts 15 minutes, carries only `launch:prepare`, and requires the preparation launcher
to equal the authenticated wallet. It has no refresh token and cannot send a transaction.

Read-only runtime checks use the same client:

```js
const health = await client.getHealth();
const indexedToken = await client.getToken(preparation.predictedTokenAddress);
```

Prepare creator-fee delivery from the indexed token record:

```js
const fees = await client.getFeeDeliveryPreparation(indexedToken.contract);
client.verifyFeeDeliveryPreparation(fees);
```

For a LaunchHub token, the indexed record binds the launch record to its active template and
resolved LP locker. The preparation contains one zero-value, unsigned transaction:

```js
// LaunchHub:
// fees.transaction.to is the LP locker resolved from the indexed activated template.
// fees.transaction.data encodes claimFees(indexedToken.contract).
```

The builder rejects a template that was never activated for the indexed launch, a token or module
mismatch, and any preparation whose target, calldata, or value drifts from that indexed
provenance. Later template deprecation blocks new launches only: tokens launched while that
version was active remain claimable through their immutable locker. The caller cannot supply a
recipient, amount, hook, pool, treasury, vault, or arbitrary call target.

The frozen legacy v4 path remains available for existing tokens and still contains three
zero-value, unsigned transactions:

```js
// fees.steps contains three zero-value, unsigned transactions:
// 1. collectRewards(token)
// 2. flushPoolFees(poolId, beneficiary)
// 3. claimFor(beneficiary)
```

Both paths are permissionless and destination-bound. A FeeLocker payment is beneficiary-account
scoped and can include earnings from several launches. The SDK cannot redirect funds, sign,
sequence confirmations, pay gas, or broadcast.

The package also exports the canonical v4 request builder, digest function, calldata encoder,
legacy fee-delivery builder/verifier, LaunchHub fee-claim builder/verifier, ABIs, serialiser, and
zero salt constant. It never stores keys, signs messages or transactions, or broadcasts
transactions.

The LaunchHub launch helpers build and verify the same direct, zero-value call used by the
DegenHood interface:

```js
const draft = buildHubLaunchDraft({
  domainId,
  templateId: 2,
  version: 1,
  name: "Example Hood",
  symbol: "EXAMPLE",
  launcher: account
});

const request = buildHubLaunchRequest({ ...draft, predictedToken });
const data = encodeHubLaunchCalldata(request);
verifyHubLaunchPreparation(preparation);
```

The verifier binds every role, metadata field, template/version/domain, salt, empty launch data,
predicted token, active module and shared token deployer. It rejects a non-direct target,
non-zero value, calldata drift, a prediction outside the canonical ordering boundary or a token
without the `…de6` suffix. It still cannot sign or submit the verified call.
