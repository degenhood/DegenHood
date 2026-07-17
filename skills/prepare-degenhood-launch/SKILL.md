---
name: prepare-degenhood-launch
description: Prepare, verify, simulate, and inspect non-custodial DegenHood launches and creator-fee delivery with the DegenHood SDK or CLI. Use when an agent needs to integrate @degenhood/sdk, run @degenhood/cli, prepare or verify unsigned launch calldata, simulate a launch on Robinhood Chain, check indexing status, or inspect and prepare the unsigned fee-delivery sequence.
---

# Prepare a DegenHood launch

Use the reviewed SDK and CLI as the source of launch semantics. Keep the creator's wallet in control
and stop at verified, unsigned calldata.

## Load the canonical context

Work from the DegenHood repository root. Read `README.md` and `SECURITY.md`, then load only the
references required by the task:

- SDK integration: `packages/sdk/README.md`
- CLI commands: `packages/cli/README.md`
- Token metadata: `examples/developer/token.example.json`
- External-wallet flow: `examples/developer/prepare-launch.ts`
- HTTP contract: `openapi/degenhood-v1.yaml`
- Security and disclosure boundary: `SECURITY.md`

Treat those files as canonical. Do not copy protocol request construction into this skill or invent
fields that the SDK does not expose.

## Enforce the safety boundary

- Keep all work on Robinhood Chain, chain ID `4663`.
- Use Template 2 unless the user explicitly supplies another reviewed template.
- Bind `launcher` to the authenticated creator wallet.
- Default `tokenAdmin`, `feeAdmin`, and `beneficiary` to the creator wallet unless the user
  explicitly chooses other addresses and reviews them.
- Require a zero-value launch transaction and a predicted token address ending `...de6`.
- Never ask for, read, store, paste, log, or transmit a private key, mnemonic, seed phrase, or
  keystore.
- Do not sign a message or transaction. Let the creator's external wallet perform any signature.
- Do not deploy or submit a transaction.
- Do not broadcast or send a transaction.
- Do not move funds, sponsor gas, publish packages, widen an allowlist, or enable production
  authentication.
- Do not invent an access token. Ask the user to place a valid short-lived token in their local
  `DEGENHOOD_ACCESS_TOKEN` environment without pasting it into chat.
- Fail closed when authentication, configuration, chain identity, verification, simulation, or
  indexing is unavailable or inconsistent.

If a request crosses one of these boundaries, complete the safe preparation or diagnostic portion
and hand the remaining wallet or operator action back to the user.

## Select the workflow

### Prepare a launch

1. Validate the metadata file and creator address without changing chain state.
2. Confirm the user has set `DEGENHOOD_ACCESS_TOKEN` locally.
3. Prepare through the reviewed local CLI:

```sh
node packages/cli/src/cli.js launch prepare \
  --file <TOKEN_JSON> \
  --account <CREATOR_WALLET> \
  --api https://api.degenhood.fun \
  > <PREPARATION_JSON>
```

4. Verify the saved response immediately:

```sh
node packages/cli/src/cli.js launch verify \
  --file <PREPARATION_JSON>
```

5. Inspect the canonical request, request digest, predicted `...de6` address, chain ID, factory
   destination, roles, zero value, and calldata before reporting readiness.

Do not print the access token or include it in a command-line argument.

### Simulate a verified launch

Verify before simulating. Then run:

```sh
node packages/cli/src/cli.js launch simulate \
  --file <PREPARATION_JSON> \
  --rpc https://rpc.mainnet.chain.robinhood.com
```

Require the RPC to report chain ID `4663`. Treat only `eth_estimateGas` and `eth_call` as approved
simulation methods. A successful simulation does not authorize signing or broadcasting.

### Integrate the SDK

Use `createDegenHoodClient` for HTTP transport and `verifyLaunchPreparation` for the returned
payload. Inject the caller's existing wallet client only for the external EIP-191 challenge
signature shown in `examples/developer/prepare-launch.ts`.

Keep these phases separate:

1. Request a wallet challenge.
2. Let the external wallet sign the exact challenge message.
3. Exchange the signature for a 15-minute `launch:prepare` session.
4. Prepare the launch with the authenticated wallet as `launcher`.
5. Call `verifyLaunchPreparation`.
6. Estimate gas and call through a read-only public client.

Never add SDK helpers that accept keys, sign, send, or broadcast.

### Check indexing

Use the predicted full token address:

```sh
node packages/cli/src/cli.js launch status \
  --token <TOKEN_ADDRESS> \
  --api https://api.degenhood.fun
```

Distinguish "not indexed yet" from API unavailability. Do not fabricate a successful launch or
token page from a preparation response.

### Inspect or prepare creator-fee delivery

Inspect beneficiary-account earnings without producing calldata:

```sh
node packages/cli/src/cli.js fees inspect \
  --token <TOKEN_ADDRESS> \
  --api https://api.degenhood.fun
```

Prepare the reviewed three-step, zero-value bundle:

```sh
node packages/cli/src/cli.js fees prepare \
  --token <TOKEN_ADDRESS> \
  --api https://api.degenhood.fun
```

Verify that the steps are `collectRewards`, `flushPoolFees`, and `claimFor`, in that order. Explain
that the final claim is beneficiary-account scoped and may combine earnings from several launches.
Do not sign, sequence confirmations, pay gas, or broadcast any step.

## Report the result

Return:

- the operation performed;
- the creator, beneficiary, chain, template, predicted token, and transaction destination;
- whether local verification passed;
- the gas estimate and call result when simulation was requested;
- any indexing or API status;
- the exact file containing the unsigned preparation; and
- the remaining user-controlled wallet or operator action.

Redact access tokens and authentication signatures. Report failures with the rejected check and
leave the workflow fail closed.
