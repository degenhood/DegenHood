# DegenHood v4.0 user disclosures

**Draft updated:** 14 July 2026
**Scope:** DegenHood v4.0 interface and launch contracts on Robinhood Chain
**Status:** operator-authored bootstrapped disclosure; not legal, tax, investment, or security advice

This document explains the intended v4.0 mechanics in plain language. Onchain contract state and
the transaction presented by a wallet are authoritative. If this document, the interface, an
indexer, or social copy conflicts with deployed bytecode, do not sign until the conflict is
resolved.

## High-risk product

Cryptoassets and memecoins are speculative and can lose all value. A transaction can fail or
execute at an unexpected price because of volatility, slippage, sequencing, MEV, liquidity,
network behavior, wallet behavior, contract defects, third-party failures, or malicious tokens.
Permanent liquidity custody does not guarantee a market, price, active liquidity, or safe trading.

DegenHood is non-custodial. It cannot recover a private key, reverse a launch or trade, return an
asset sent to the wrong address, or erase a public blockchain record.

## Standard launch

Each standard v4.0 launch commits the following before signature:

- token name, symbol, contract metadata, and image URI;
- launcher, token admin, fee admin, and initial beneficiary;
- approved factory template and user salt; and
- a fixed 100B supply, standard tick range, WETH pairing, and `…de6` address rule.

The token supply goes to a single-sided Uniswap v4 position. The LP NFT is held permanently by the
specified DegenHood LP locker, which has no principal-withdrawal path. New templates can affect
future launches only; they do not rewrite an existing pool's hook, locker, roles, or economics.

## LP and protocol fees are separate

The pool LP fee is 0.7%. It is not the protocol fee.

- WETH-side LP fees collected from the locked position are credited to the recorded beneficiary.
- Token-side LP fees are split 80% to burn and 20% to a separate operator-controlled Token Reserve.
- The Token Reserve is not the operating treasury and is not a current `$DEGEN` holder, locker,
  governance, buyback, burn, or reward entitlement. Assets received by the reserve may be
  illiquid, malicious, or worthless.

A separate hook fee applies to the gross WETH basis of buys and sells:

- permanent protocol component: 0.5%;
- initial 80% total hook rate, consisting of 0.5% permanent plus at most 79.5% temporary;
- schedule: temporary component decays parabolically to zero over 30 seconds from confirmed pool
  initialization;
- temporary proceeds: 50% beneficiary and 50% protocol;
- permanent component and integer rounding dust: operating treasury; and
- coverage: exact-input buys, exact-output buys, exact-input sells, and exact-output sells.

V4.0 has no sniper auction and no auction payment. The fee preview is informational: block timing,
ordering, direction, exact-output gross-up, integer rounding, slippage, and pool state determine an
actual transaction.

## Beneficiary and administration roles

The launcher, token admin, fee admin, and beneficiary may be different addresses.

- The token admin controls token metadata only.
- The fee admin can update the fee admin and can change the beneficiary for future accrual.
- Changing a beneficiary first collects and checkpoints available LP fees, flushes hook fees to
  the prior beneficiary, and then changes future accrual.
- The beneficiary receives credited WETH but does not gain token-admin or fee-admin authority.

A launcher can nominate any non-zero beneficiary. Nomination does not prove that the beneficiary
knows about, controls, created, supports, or endorses the token. Verify role addresses before
signing. A mistaken address is not automatically reversible; only the current fee admin can use
the onchain update path.

## Permissionless fee delivery

Any address may trigger these steps:

1. collect LP rewards from the permanently held position;
2. flush pending hook accounting; and
3. call `claimFor` on the FeeLocker.

The caller cannot select a payout destination. WETH always goes to the recorded beneficiary. The
three steps can require three wallet confirmations and can be retried after a partial sequence.
A FeeLocker balance is scoped to a locker and beneficiary, not a single token; one `claimFor` may
pay an account-wide balance accumulated across several launches.

## Routing, discovery, and data limitations

DegenHood launches a dynamic-fee Uniswap v4 pool with a custom hook. The supported and fork-rehearsed route
uses Robinhood's Universal Router with empty hook data, but the contracts
do not enforce one router and compatibility is not guaranteed. Uniswap Labs, external routers,
DexScreener, wallets, explorers, and indexers may omit or delay pools, calculate data differently,
route elsewhere, or stop supporting Robinhood Chain or v4 hooks.

The DegenHood BFF is a first-party discovery fallback for launch, role, fee, burn, reserve, and
pool records. It can also be delayed, unavailable, or wrong. Verify contract addresses, roles,
template ID, pool ID, fee state, and transactions onchain.

## `$DEGEN` at v4.0 launch

`$DEGEN` is intended to be DegenHood's freely tradable flagship token. Merely holding it at v4.0
launch creates no current lock, reward, fee-share, governance, buyback, or burn entitlement.
Possible later utility is outside the immutable day-zero launch mechanics and may change or never
be implemented.

## Source lineage and security boundary

The isolated `contracts-v4/` project uses pinned Uniswap, OpenZeppelin, Permit2, Universal Router,
and Foundry dependencies. Its architecture materially adapts MIT-marked Clanker patterns and
adds DegenHood-specific fee math, role commitments, routing, and custody behavior.

Upstream audit reports cover only the files and commits stated in those reports. They do not cover
DegenHood modifications, Robinhood deployment configuration, the frontend, the indexer, operator
procedures, or future templates. “Upstream audit lineage” is not a DegenHood audit. DegenHood v4.0
has local tests, fuzzing, invariants, fork rehearsal, and static-analysis review, but no completed
independent DegenHood audit is claimed.

## Public and private information

Wallet addresses, launch roles, beneficiary changes, metadata, transactions, trades, and fee
events are public onchain and may be copied indefinitely. Operator role addresses can be published
for verification. The bootstrapped operator does not publish a private home address, government
identity, or unrelated private information through the interface. See the in-app Privacy Notice
for website, infrastructure, upload, security-log, retention, recipient, and rights information.

## Before signing

- Confirm Robinhood Chain ID `4663`.
- Confirm the verified factory, template, hook, LP locker, FeeLocker, token, and role addresses.
- Confirm name, symbol, metadata, image, beneficiary, fee admin, token admin, and predicted token
  address.
- Read the fee preview as an estimate, not a quote or execution guarantee.
- Understand that LP principal is permanently locked and blockchain transactions are irreversible.
- Do not sign if the wallet calldata, displayed role tuple, or onchain state differs from what you
  intended.

Current official consumer guidance continues to describe cryptoassets as high risk and capable of
total loss. Privacy notices should clearly explain purposes, recipients, retention, transfers, and
individual rights. Reference material: [FCA crypto risk guidance](https://www.fca.org.uk/investsmart/investing-crypto)
and [ICO privacy-information guidance](https://ico.org.uk/for-organisations/uk-gdpr-guidance-and-resources/individual-rights/the-right-to-be-informed/what-privacy-information-should-we-provide/).
