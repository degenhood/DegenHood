# @degenhood/cli

Thin, non-custodial wrapper around `@degenhood/sdk` and the authenticated DegenHood launch-preparation endpoint.

## Install

```sh
npm install @degenhood/cli@0.1.0
npx @degenhood/cli@0.1.0 --help
```

Version `0.1.0` is the first stable package release and is published under the `latest` dist-tag.
Access to the production launch-preparation API remains controlled and wallet-allowlisted.

Copy [`examples/developer/token.example.json`](../../examples/developer/token.example.json) to
start. Template 2 is the default, and omitted role fields safely resolve to the creator wallet.
The companion
[`examples/developer/prepare-launch.ts`](../../examples/developer/prepare-launch.ts) shows the
external-wallet session exchange used to obtain a short-lived access token. The CLI accepts that
token but does not store wallet keys, sign, send, or broadcast.

## Usage

```sh
export DEGENHOOD_ACCESS_TOKEN="..."
degenhood launch prepare \
  --file token.json \
  --account 0xYourCreatorWallet
```

The access token may be an existing Privy browser token or a 15-minute wallet session obtained
through the SDK/API challenge exchange. The CLI does not request a private key and does not sign
the challenge; produce the EIP-191 signature in an external wallet, exchange it through
`@degenhood/sdk` or the documented API, then pass only the resulting short-lived token here.

`token.json` contains launch metadata:

```json
{
  "name": "Example Hood",
  "symbol": "EXAMPLE",
  "description": "The creator story.",
  "website": "https://example.com",
  "x": "@example",
  "telegram": "https://t.me/example",
  "imageURI": "https://images.example.com/token.png",
  "templateId": 2
}
```

The result contains the canonical request, digest, predicted `...de6` token address, and unsigned factory calldata. The account passed with `--account` remains the on-chain launcher and must sign and fund the transaction in a wallet, Safe, or external automation runner.

Verify a saved preparation locally:

```sh
degenhood launch verify --file preparation.json
```

Run both `eth_estimateGas` and `eth_call` against a selected RPC without changing chain state:

```sh
degenhood launch simulate --file preparation.json --rpc https://rpc.mainnet.chain.robinhood.com
```

Simulation first verifies that the RPC reports the same Robinhood Chain ID (`4663`) bound into the preparation.

Check whether the predicted token has reached the DegenHood index:

```sh
degenhood launch status --token 0xPredictedToken --api https://api.degenhood.fun
```

Inspect beneficiary-account earnings without returning calldata:

```sh
degenhood fees inspect --token 0xToken --api https://api.degenhood.fun
```

Prepare and verify the three unsigned v4 fee-delivery transactions:

```sh
degenhood fees prepare --token 0xToken --api https://api.degenhood.fun
```

The output calls `collectRewards`, `flushPoolFees`, then `claimFor`. A wallet or external runner must review and sign each transaction in order. The final FeeLocker claim may combine several launches for the same beneficiary.

`DEGENHOOD_API_URL`, `DEGENHOOD_ACCESS_TOKEN`, and `DEGENHOOD_RPC_URL` are supported environment alternatives. The CLI deliberately has no private-key, keystore, message-signing, transaction-signing, send, or broadcast command.
