# DegenHood developer toolkit

[![CI](https://github.com/degenhood/DegenHood/actions/workflows/ci.yml/badge.svg)](https://github.com/degenhood/DegenHood/actions/workflows/ci.yml)
[![CodeQL](https://github.com/degenhood/DegenHood/actions/workflows/codeql.yml/badge.svg)](https://github.com/degenhood/DegenHood/actions/workflows/codeql.yml)
[![SDK on npm](https://img.shields.io/npm/v/@degenhood/sdk?label=%40degenhood%2Fsdk)](https://www.npmjs.com/package/@degenhood/sdk)
[![CLI on npm](https://img.shields.io/npm/v/@degenhood/cli?label=%40degenhood%2Fcli)](https://www.npmjs.com/package/@degenhood/cli)

Public developer tooling for preparing and verifying DegenHood token launches on Robinhood Chain
(chain ID `4663`).

This repository is intentionally limited to the public integration surface. It does not contain
the production application, deployment configuration, contract source, operator procedures, or
credentials.

## Packages

| Package | Purpose |
| --- | --- |
| [`@degenhood/sdk`](packages/sdk) | Build requests, call the preparation API, verify returned calldata, and inspect indexed launches |
| [`@degenhood/cli`](packages/cli) | Prepare, verify, simulate, and inspect launches from a terminal |

Both packages are MIT licensed and require Node.js 20 or newer.

```sh
npm install @degenhood/sdk@0.1.0
npm install @degenhood/cli@0.1.0
```

## SDK quickstart

```js
import {
  createDegenHoodClient,
  verifyLaunchPreparation
} from "@degenhood/sdk";

const client = createDegenHoodClient({
  baseUrl: "https://api.degenhood.fun",
  accessToken: process.env.DEGENHOOD_ACCESS_TOKEN
});

const preparation = await client.prepareLaunch({
  name: "Example Hood",
  symbol: "EXAMPLE",
  launcher: account,
  tokenAdmin: account,
  feeAdmin: account,
  beneficiary: account,
  templateId: 2
});

verifyLaunchPreparation(preparation);
```

The response contains a predicted `...de6` token address and an unsigned, zero-value transaction.
The SDK does not accept wallet keys, sign transactions, pay gas, or broadcast.

See the complete external-wallet flow in
[`examples/developer/prepare-launch.ts`](examples/developer/prepare-launch.ts).
Production launch preparation is currently wallet-allowlisted.

## CLI quickstart

Start with [`examples/developer/token.example.json`](examples/developer/token.example.json), then:

```sh
export DEGENHOOD_ACCESS_TOKEN="your-short-lived-token"

npx @degenhood/cli@0.1.0 launch prepare \
  --file examples/developer/token.example.json \
  --account 0xYourCreatorWallet \
  > preparation.json

npx @degenhood/cli@0.1.0 launch verify --file preparation.json
```

Optional simulation uses `eth_estimateGas` and `eth_call` only:

```sh
npx @degenhood/cli@0.1.0 launch simulate \
  --file preparation.json \
  --rpc https://rpc.mainnet.chain.robinhood.com
```

Review the full command reference in [`packages/cli/README.md`](packages/cli/README.md).

## API and agent integration

- [`openapi/degenhood-v1.yaml`](openapi/degenhood-v1.yaml) documents the public preparation API.
- [`skills/prepare-degenhood-launch`](skills/prepare-degenhood-launch) is a portable agent skill
  for the safe prepare → verify → simulate workflow.

To install the skill for a local Codex setup:

```sh
mkdir -p ~/.codex/skills
cp -R skills/prepare-degenhood-launch ~/.codex/skills/
```

The skill fails closed and explicitly prohibits requesting keys, signing, deploying, moving funds,
or broadcasting.

## Verification

```sh
npm ci --prefix packages/sdk
npm ci --prefix packages/cli
npm test
npm run verify:packages
```

`verify:packages` creates the exact npm tarballs, checks their contents against an allowlist, then
installs and exercises them in an empty temporary project.

Run the optional production read-only smoke check with a known indexed token:

```sh
DEGENHOOD_API_URL=https://api.degenhood.fun \
DEGENHOOD_TOKEN=0xTokenAddress \
npm run smoke:read-only
```

No authentication is used unless the explicit preparation-smoke flag is enabled.

## Security

Please report vulnerabilities privately through [GitHub Security Advisories](SECURITY.md). Never
include live keys, access tokens, funded-wallet signatures, or credentials in an issue.

## License

[MIT](LICENSE)
