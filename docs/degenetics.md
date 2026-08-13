# Degenetics · DegenHood Degens

Degenetics is DegenHood's backed-pack and activated-holder reward layer on Robinhood Chain
(`chainId 4663`). The collection is **DegenHood Degens**: 1,000 ERC-721 packs governed by the
deployed `DegenhoodDegens` contract.

## Core economics

| Rule | Deployed value |
| --- | --- |
| Maximum packs | 1,000 |
| `$DEGEN` backing per pack | 66,666,666 |
| Phase-one supply | 500 |
| Phase-two mint fee | 10% of backing notional, paid in ETH |
| Redemption fee | 10% of backing notional, paid in ETH |
| Reroll fee | 15% of backing notional, paid in ETH |
| ETH fee split | 66.66% holders · 16.67% burn lane · remainder treasury |
| ERC-2981 royalty | 3.33% advisory royalty |

Backing is held by the contract and returned on redemption. Activation consumes `$DEGEN`, assigns
weight and enables a share of eligible ETH and SPY distributions. Activation is cleared on transfer.
Claims are pull-based; no fee volume, rarity, reward amount, liquidity or market value is guaranteed.

## Deployed graph

| Component | Function |
| --- | --- |
| `DegenhoodDegens` | escrow, mint, reveal, activation, rewards, claims and redemption |
| `HoodConductor` | operator-fed commit/reveal entropy with permissionless snap/rearm |
| `V4PriceSource` | DEGEN/WETH v4 pool price read used for notional fee calculation |
| Two `HoodFeeForwarder` instances | LP-fee and royalty WETH unwrap/routing |
| `HoodFeeFlusher` | permissionless harvest, claim and forward composition |

Full addresses and explorer links are in [`deployments.md`](deployments.md).

## Source provenance

The production graph does not correspond to one repository commit. Each explorer main source was
matched exactly to the Git blob used for that deployed contract. The source map is recorded in
`contracts-degenetics/SOURCE-MAP.json`, and `PUBLIC-MANIFEST.json` records the source commit for
every exported file. This avoids presenting later, undeployed source as the live implementation.

## Authority and trust boundaries

- `DegenhoodDegens` retains an admin for metadata and documented one-shot configuration.
- `HoodConductor` has an owner that can rotate its operator; entropy availability depends on operator
  commit/reveal liveness.
- Pool reads depend on the configured Robinhood Chain and Uniswap v4 contracts.
- Fee and royalty delivery depends on their configured sources actually paying the forwarders.
- The deployed principal's final-art provenance path is not represented as usable; tier art remains
  the supported principal metadata path.
- Operator scripts, keeper seeds, wallets and hosted automation are not part of this repository.

## Verify

```sh
cd contracts-degenetics
./scripts/install-dependencies.sh
forge fmt --check
forge build
forge test
```

Then compare each compiled source and runtime record with the full address in `deployments.md`.
