# DegenHood v4 notices

This isolated Foundry project uses the exact dependency revisions listed below. Dependency source
and licence texts remain in `lib/`; this notice does not replace those terms.

| Dependency | Revision | Licence at pinned revision |
|---|---|---|
| foundry-rs/forge-std | `77041d2ce690e692d6e03cc812b57d1ddaa4d505` | MIT or Apache-2.0 |
| OpenZeppelin/openzeppelin-contracts | `a7d38c7a3321e3832ca84f7ba1125dff9a91361e` | MIT |
| Uniswap/v4-core | `5f00c8416c19a7e6a5a5d0539fad30fd124f7b86` | mixed BUSL-1.1/MIT; see per-file SPDX and `lib/v4-core/licenses/` |
| Uniswap/v4-periphery | `9628c36b4f5083d19606e63224e4041fe748edae` | MIT |
| Uniswap/universal-router | `3663f6db6e2fe121753cd2d899699c2dc75dca86` | GPL-3.0 |
| Uniswap/permit2 | `cc56ad0f3439c502c246fc5cfcc3db92bb8b7219` | MIT |

Files materially adapted from Clanker preserve their upstream MIT SPDX identifier and are mapped
to exact upstream paths and hashes in the source-lineage manifest. No upstream audit or
licence is represented as a DegenHood security review.

## Adapted source lineage

### `src/DegenHoodFeeLocker.sol`

- Upstream: `clanker-contracts/v4.0/src/ClankerFeeLocker.sol` at
  `b004c2edda29fa282a16d5d1441a26484f70b37f` (MIT).
- Retained concepts: owner-managed depositor authorization, balance-delta-backed deposits,
  beneficiary accounting, checks-effects-interactions claims, `SafeERC20`, and reentrancy guard.
- Security-relevant changes: WETH is the only asset; depositor authorization can be revoked;
  zero addresses/amounts/receipts are rejected; liabilities are tracked explicitly; zero-balance
  claims are idempotent; `claimFor` is permissionless but can pay only the recorded beneficiary;
  native ETH and arbitrary tokens are not accepted through any custody function; and no owner
  withdrawal or rescue path exists.
- Interface change: arbitrary `token` and caller-selected recipient parameters are absent.

The DegenHood implementation is a material adaptation and requires its own review. The pinned
Clanker review/audit history does not cover these changes.

### `src/DegenHoodV4Factory.sol`

- Upstream: `clanker-contracts/v4.0/src/Clanker.sol` at
  `b004c2edda29fa282a16d5d1441a26484f70b37f` (MIT), plus DegenHood's v3
  `contracts/src/DegenHoodFactoryV3.sol` CREATE2 role-binding and vanity-address lineage.
- Retained concepts: non-proxy future-launch versioning, configuration-owner template approval,
  one-way retirement of old launch paths, atomic token/pool/liquidity creation, and CREATE2 address
  prediction.
- Security-relevant changes: arbitrary hooks, extensions, MEV modules, per-launch fee parameters,
  paired assets, supplies, tick ranges, and mutable protocol recipients are absent. Template IDs are
  append-only and bind an exact factory-owned hook/locker pair plus their runtime code hashes. Each
  launch commitment binds launcher, token admin, fee admin, beneficiary, template, full metadata,
  and user salt; the caller must be the committed launcher. WETH, treasury, Token Reserve, supply,
  fees, decay, ticks, spacing, and `...de6` vanity mask are fixed. Launch is atomic across token
  deployment, hook registration, pool initialization, and permanent LP placement. Deprecation only
  blocks future launches, and configuration ownership cannot be transferred to either asset-custody
  address.

The DegenHood implementation is a material adaptation and requires its own review. The pinned
Clanker review/audit history does not cover these changes.

### `src/DegenHoodV4LpLocker.sol`

- Upstream: `clanker-contracts/v4.0/src/lp-lockers/ClankerLpLockerMultiple.sol` at
  `b004c2edda29fa282a16d5d1441a26484f70b37f` (MIT).
- Retained concepts: factory-only initial placement, Permit2/PositionManager settlement,
  locker-owned position NFTs, zero-liquidity fee checkpointing, paired-asset collection, and
  permissionless reward collection.
- Security-relevant changes: the configurable position/reward arrays, multiple recipients,
  owner role, ETH withdrawal, ERC-20 withdrawal, NFT receiver, unlocked-pool collection path, and
  arbitrary reward administration are removed. DegenHood accepts exactly one 100B token/WETH
  position at ticks `-230400/-120000` with spacing 200. The NFT and launch-token rounding dust have
  no withdrawal path. WETH LP fees can only be stored for the recorded beneficiary; launched-token
  LP fees send a floor 20% to the immutable Token Reserve and the entire remainder to the burn sink.
  The distinct fee admin may update that beneficiary or transfer its own role in one transaction,
  but cannot alter rates, destinations, custody, or old credits. A beneficiary update atomically
  checkpoints both LP fees and the hook's backed temporary entitlement to the old beneficiary before
  changing either active pointer. The locker is the hook's per-pool beneficiary controller, so the
  factory/configuration authority retains no recipient override for that pool. Failed custody, token
  distribution, hook flush, or fee-locker operations revert the whole checkpoint and role update.

The DegenHood implementation is a material adaptation and requires its own review. The pinned
Clanker review/audit history does not cover these changes.

### `src/DegenHoodV4Hook.sol`

- Upstream: `clanker-contracts/v4.0/src/hooks/ClankerHookV2.sol` and
  `src/hooks/ClankerHookStaticFeeV2.sol` at
  `b004c2edda29fa282a16d5d1441a26484f70b37f` (MIT).
- Retained concepts: factory-authorized exact PoolKey registration, launched-token/WETH ordering,
  a dynamic-fee Uniswap v4 pool, guarded initialization, PoolId-keyed launch state, fixed-fee
  refresh through `updateDynamicLPFee`, and before/after swap return-delta permissions.
- Security-relevant changes: open pool creation, configurable tick/spacing/paired token, extensions,
  MEV modules, mutable/global protocol-rate state, owner controls, and LP-relative protocol fees are
  removed. The only registered pair is launched token (currency0) / immutable WETH (currency1),
  initialization is factory-only at tick `-230400`, and the LP fee is fixed at 7,000 unibips. The
  custom WETH fee uses direct per-pool time math, backs pending credits with PoolManager claims,
  preserves beneficiary entitlement across recipient updates, and exposes only a permissionless
  burn/take flush to the immutable Operating Treasury and WETH fee locker. No arbitrary callback,
  payout recipient, rescue path, or mutable fee schedule is retained. Each pool binds a beneficiary
  controller at registration; when that controller is the LP locker, the factory cannot redirect the
  pool's creator-class WETH after launch.

The DegenHood implementation is a material adaptation and requires its own review. The pinned
Clanker review/audit history does not cover these changes.

### `src/DegenHoodV4HookV2.sol`

- Lineage: versioned DegenHood adaptation of `src/DegenHoodV4Hook.sol`, which in turn records the
  Clanker Hook lineage immediately above.
- Retained behavior: exact token/WETH pool registration, fixed 0.7% LP fee, four-mode WETH Hook
  fee math, 30-second parabolic launch surcharge, PoolManager-claim backing, and per-beneficiary
  temporary-fee attribution.
- Security-relevant changes: protocol-owned WETH is represented by one global pending counter and
  can be redeemed by the next swap on any registered pool. The catchable self-call clears its
  accounting before burning the exact WETH claim and taking the same amount directly to the
  immutable treasury; a failed subcall reverts those effects and lets the trade continue. The
  manual quiet-period fallback is permissionless and fixed-destination. The legacy
  `flushPoolFees` selector is retained for LP-locker compatibility but delivers only the named
  beneficiary's already-attributed WETH and returns zero protocol payment.
- Deliberate omissions: no LP reward auto-collection, launched-token sale, router, conversion
  preference, caller-selected recipient, token enumeration, or batch pool loop was added.

This version is new DegenHood code and requires its own review. No prior DegenHood or Clanker audit
is represented as covering its global accounting or swap-triggered claim redemption.
