# @degenhood/sdk

Shared, non-custodial request tooling for DegenHood v4 launches on Robinhood Chain.

## Install

```sh
npm install @degenhood/sdk@0.1.0
```

Version `0.1.0` is the first stable package release and is published under the `latest` dist-tag.
Access to the production launch-preparation API remains controlled and wallet-allowlisted.

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

Prepare the permissionless v4 creator-fee delivery sequence from the indexed token record:

```js
const fees = await client.getFeeDeliveryPreparation(indexedToken.contract);
client.verifyFeeDeliveryPreparation(fees);

// fees.steps contains three zero-value, unsigned transactions:
// 1. collectRewards(token)
// 2. flushPoolFees(poolId, beneficiary)
// 3. claimFor(beneficiary)
```

The final FeeLocker claim is beneficiary-account scoped and can include earnings from several launches. The SDK cannot redirect funds, sign, sequence confirmations, pay gas, or broadcast.

The package also exports the canonical v4 request builder, digest function, calldata encoder, fee-delivery builder/verifier, ABIs, serialiser, and zero salt constant. It never stores keys, signs messages or transactions, or broadcasts transactions.
