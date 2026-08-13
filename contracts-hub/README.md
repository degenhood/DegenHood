# DegenHood LaunchHub contracts

This is the separately versioned Foundry project for the immutable LaunchHub and its reviewed
modules. LaunchHub production contracts do not import production code from the frozen
`contracts-v4/` stack. Differential tests may import the frozen implementation to prove
behavioral equivalence.

The project may reuse the repository's pinned third-party dependency checkouts. Every DegenHood
contract and library crossing into this trust boundary is copied, tested, and reviewed here.

Nothing in this project authorizes deployment or broadcast.

Run the contract suite through `./test-contracts.sh`. The wrapper first builds the pinned
Uniswap v4 `PoolManager` creation artifact with Solidity 0.8.26, then runs the LaunchHub
contracts and tests with Solidity 0.8.28. This preserves the production compiler boundary.

## LaunchHub V2 clean relaunch candidate

`LaunchHubV2` is a fresh kernel beside the historical LaunchHub. It seals exactly two genesis
templates, both at version `2`:

- template `2`: WETH V4 with six permanently locked positions, initial tick `-230200`, and
  `10.070264234995 WETH` starting spot FDV;
- template `4`: canonical raw-SPY V4 with the shifted six-position curve, initial tick `-221000`,
  and `25.268054989214 SPY` starting spot FDV.

Both curves use shares `6/34/22/17/10/11%`. Creator quote fees remain destination-bound and
claimable through `claimFees(token)`. Measured token-side LP fees route 80% to the dead address
and 20% to the immutable token-reserve wallet. Treasury and buyback quote claims use the reviewed
external-self-call, one-swap-behind settlement pattern from `DegenHoodV4HookV2`, without importing
or modifying the frozen deployed V4 tree.

The deterministic graph is prepared with:

```bash
node scripts/build-launchhub-v2-unsigned-deployment-package.mjs \
  --manifest docs/handoffs/2026-07-24-launchhub-v2-unsigned-genesis-manifest.template.json \
  --output /absolute/path/to/package.json

node scripts/verify-launchhub-v2-unsigned-deployment-package.mjs \
  --package /absolute/path/to/package.json

python3 scripts/launchhub-v2-consistency-scan.py
```

The checked-in package is a rehearsal only. Final `latest` and `pending` nonces must be reconciled
and the package rebuilt immediately before an operator-run test deployment. No script in this
lane signs, sends, broadcasts, funds, or authorizes a deployment.

The checked-in DEGEN Mode fixture applies tranche shares as integer pips. This intentionally
removes the tiny binary-float artifacts produced when the reference Python model constructs its
`6/54/22/12/5/1` shares from decimal floats before entering the integer Uniswap math.

The DEGEN sibling stack uses `DegenV1FeeLocker` for creator WETH credits. Its LP-locker and hook
depositor addresses are immutable, claims are permissionless but destination-bound, and there is
no owner, depositor setter, sweep, redirect, expiry, or arbitrary-token path. Template lockers
implement the common `ILaunchFeeClaimer.claimFees(token)` surface; the Hub kernel does not route or
interpret post-launch fee delivery.

`DegenV1LpLocker` permanently holds the six approved `6/54/22/12/5/1` tranche positions.
Its permissionless `claimFees(token)` call atomically collects all positions, applies the token-side
80/20 burn/reserve split, flushes the hook's treasury/buyback/creator buckets, and pays only the
recorded beneficiary.

`DegenBuybackVault` is the required DEGEN hook buyback destination. It is ownerless and
permissionless, stores one immutable live `$DEGEN`/WETH PoolKey, and calls PoolManager directly.
`executeBuyback()` accepts no caller parameters. It traverses initialized ticks to the immutable
one-percent boundary, sizes the offered WETH downward after the live hook and pool fees, and uses
the native v4 boundary as a backstop. The call must consume the complete pre-sized offer or it
reverts atomically, preventing hook fees on unconsumed principal. Every positive `$DEGEN` output is
sent to the fixed sink in the same transaction. This is removal from circulation:
`DegenHoodTokenV4.totalSupply()` does not decrease. There is no oracle, minimum output, threshold,
cooldown, reversible pause, sweep, router approval, or caller-selected route. On Robinhood Chain,
both the vault and DEGEN hook reject any route other than the pinned live `$DEGEN` pool.

The fresh Hub-bound `STANDARD_V1` sibling stack reproduces the frozen v4 Standard launch policy:
one permanent full-range position from tick `-230400` to `-120000`, a dynamic 0.7% LP fee, and
the 30-second launch surcharge that begins at an 80% total effective fee. Its permanent 0.5%
protocol hook fee, temporary creator/protocol split, and exact-output rounding are checked
differentially against the frozen fee math. `StandardV1LpLocker.claimFees(token)` reduces the
legacy three-transaction collection path to one permissionless, destination-bound transaction
while retaining the token-side 80/20 burn/reserve split.

## LaunchHub V3 template candidate

The V3 candidate adds template `2`/version `3` for WETH and template `4`/version `3` for SPY to
the existing immutable `LaunchHubV2` kernel. These are additive templates, not migrations. All
historical tokens, hooks, modules, lockers, and launch records retain their deployed behavior.
Nothing under `contracts-v4/` or `contracts/` is modified.

`DegenHoodTokenV5` is a new standalone ERC-1167 implementation; it does not import or inherit
`DegenHoodTokenV4`. Its implementation instance is permanently locked, while each clone can be
initialized once with a fixed 100B supply, module recipient, token admin, and two IPFS sha2-256
digests. It adds `burn`, allowance-aware `burnFrom`, EIP-2612 permit, EIP-5267 domain discovery,
irreversible metadata freezing, and post-freeze `renounceTokenAdmin()` for a permanently admin-less
token. Slot 0 packs the admin at bytes 0–19, `initialised` at byte 20,
`metadataFrozen` at byte 21, `flatEndTime` at bytes 22–26, and `rampEndTime` at bytes 27–31.
Metadata and image digests occupy separate slots and resolve as
`ipfs://f01701220<64 lowercase hex>`; a zero digest resolves to an empty string. Arbitrary URI
schemes are rejected by the kernel-bound clone deployer.

Every clone fixes PoolManager, PositionManager, its launch module, and its permanent locker during
initialization. For 60 seconds after initialization, ordinary transfers are limited to 2.2% of
fixed supply and ordinary recipient wallets to 2%. Over the next 60 seconds, both caps increase
linearly to 100%, and at `rampEndTime` the transfer path short-circuits to unrestricted behavior.
Both phases use `block.timestamp`; neither L2 block cadence nor Solidity's parent-chain
`block.number` semantics can alter their duration. Transfers into structural settlement addresses and system
transfers from the module or locker cannot strand liquidity or block sells; PoolManager transfers
to ordinary buy recipients remain capped. There is no owner override, pause, extension, mutable
exemption list, pool lock, or sell switch.

These durations are fixed in the token implementation and are not initializer inputs. Changing or
removing them requires a new token implementation, clone deployer, and LaunchHub template version;
existing clones retain their original immutable schedule.

Each V3 hook stores its internal pool configuration in exactly two slots: slot 0 contains the
token, `uint40 initializedAt`, and status byte; slot 1 contains the beneficiary. The external
getter still returns the original six-field tuple. `beneficiaryController` is the corresponding
new LP locker, captured immutably from the fee locker at hook construction. It is a contract
binding, not an operator or mutable administrator.

The V3 deployment graph intentionally creates new instances of the existing `DegenV1FeeLocker`
and `DegenSpyV1FeeLocker` contract types. There is no missing V3 fee-locker source: these lockers
hold and pay only the quote asset and never interact with the launched token, so the V5 token's
`burn()` behavior cannot reach them. Each instance is constructed with the new V3 hook and LP
locker as its only allowed depositors; those immutable bindings are verified in integration tests.

Both quote families use ten permanent positions with shares
`1.72/31.45/4.58/27.64/9.53/2.09/1/1/1/19.99%`. WETH begins at tick `-239400`; SPY begins at
`-230200`; both end at max usable tick `887200`. The module transfers the 100B supply once to
PositionManager and submits ten mints plus direct settlement with `payerIsUser=false`. All NFTs
and any integer-liquidity dust go to the new immutable locker. No approval, NFT withdrawal,
principal withdrawal, dust sweep, rescue, upgrade, or arbitrary-call path exists. Token-side LP
fees burn 80% from total supply and send 20% to the immutable reserve; quote-side fee behavior
remains intact across the four swap quadrants. In the two quadrants that reserve the quote fee in
`beforeSwap`, `afterSwap` requires complete quote-side settlement. A binding price limit that
would partially fill the request reverts the entire swap. Standard exact-input/min-output and
exact-output/max-input routes remain compatible, as do nonbinding price limits.

Protocol quote balances accumulate globally inside each hook until anyone calls that lane's
`flushProtocolFees()`. There is no automatic per-swap sweep. The caller supplies neither amount
nor recipient: settlement is atomic and can pay only the constructor-bound operating treasury
and lane-specific buyback vault. Creator balances remain isolated per pool and beneficiary.

The already-deployed WETH and SPY buyback vaults also remain unchanged. Both are ownerless and
permissionless: anyone may pay gas to call `executeBuyback()` subject to each vault's immutable
execution rules. An off-chain DegenHood keeper may call that same public function periodically,
but it has no privileged execution or recovery authority. There is deliberately no threshold,
operator gate, pause, sweep, or emergency fund-recovery path.

The unsigned preparation lane is:

```bash
(cd contracts-hub && npm ci && forge build)

node contracts-hub/scripts/prepare-launchhub-v3-template.mjs \
  --input /absolute/path/to/reviewed-input.json \
  --output /absolute/path/to/new-unsigned-package.json

node contracts-hub/scripts/verify-launchhub-v3-unsigned-deployment-package.mjs \
  --package /absolute/path/to/new-unsigned-package.json \
  --rpc-url "$ROBINHOOD_RPC_URL"
```

The output contains ten zero-value deployment transactions and four zero-value governance
envelopes. It never accepts keys, authorization, send, or broadcast inputs, never overwrites an
output file, and marks deployment and governance account nonces for final repinning. Inputs are
restricted to the reviewed Robinhood production graph, and the output carries the pinned block
and runtime-code commitments used by the read-only replay test. Preparation forces a fresh
`forge build --force`; verification rejects nonce drift and any predicted address that already
has code. `manifestHash` is review-bound, content-addressed disclosure metadata included in the
kernel proposal hash. It is not, by itself, an on-chain proof of the module's economics; pinned
runtime hashes and independent review are the security controls. The exact
input schema, measurements, and remaining gates are documented in
`docs/handoffs/2026-07-26-launchhub-v3-candidate-evidence.md`.

The `V3` template, `V5` token, and already-deployed `LaunchHubV2` labels are internal integration
identifiers and remain unchanged. Public surfaces expose **LaunchHub** and **Degen Token** only;
template IDs and versions stay out of product copy. Template-version V3 source lives under
`src/launchhub-v3/` and `src/launchhub-spy-v3/`, leaving `src/degen-v3/` to retain its historical
meaning of Degen V1 on Uniswap V3.

No V3 deployment, proposal, approval, canary, funding, activation, signing, or broadcast is
authorized by this repository state.
