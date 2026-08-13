# Agent instructions — public repository

This repository is the public, reviewable DegenHood core. It is not an operator console.

## Product vocabulary

Use: DegenHood, `$DEGEN`, Degen LaunchHub, launch, creator, token admin, fee admin, beneficiary,
treasury, buyback, burn, permanently locked LP, activated Degen, Degenetics and `…de6` vanity.

Do not introduce unrelated project vocabulary or imply that private systems are public.

## Safety boundary

- Never request, read, store or print private keys, seed phrases, access tokens or wallet signatures.
- Never sign, send or broadcast a transaction.
- Never run a script with `--broadcast` or add signing/broadcast capability to SDK/CLI code.
- Treat contract deployment, treasury movement, funding and production configuration as operator-only.
- Use local simulation and read-only RPC calls for verification.
- Do not weaken target, chain, zero-value, calldata or vanity-address verification.
- Do not claim a component is deployed, active, immutable, audited or verified without public evidence.

## Change rules

- Read `README.md`, `ARCHITECTURE.md` and `DUE_DILIGENCE.md` first.
- Keep one coherent concern per pull request and add a focused regression test.
- `contracts-v4` is frozen. Any source change requires a fresh security review.
- Contract changes must pass formatting, build and tests and explain changed trust assumptions.
- SDK/CLI packages remain non-custodial and their exact tarball contents must pass allowlist guards.
- Delete before adding dependencies; justify any new runtime dependency.
- Never add private service implementation, operator procedures or internal hostnames to this repo.

## Verification map

```sh
# Public repository boundary and documentation
./scripts/verify-public-core.sh

# Frozen v4
(cd contracts-v4 && forge fmt --check && forge test)

# LaunchHub
(cd contracts-hub && forge fmt --check && forge test)

# Public JavaScript surfaces
npm test --prefix packages/sdk
npm test --prefix packages/cli

# Degenetics
(cd contracts-degenetics && ./scripts/install-dependencies.sh && forge fmt --check && forge test)
```

If a required check cannot run, report the exact missing dependency or public fixture. Do not reach
into a private repository to make the public build pass.

## Contributions

This repository is generated from a private canonical source. Propose changes here normally; an
accepted public change will be ported into canonical, verified, and returned in a later public snapshot.
Do not assume public commit hashes are canonical commit hashes.
