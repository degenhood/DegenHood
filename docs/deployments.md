# Production deployments

> **Reconciliation:** Robinhood Chain block `35474835`
> (`0xb373803c8bae7e9efc0e88f8aa730614cdb5b85095bbce0b921cf5331d5461ea`) on 2026-08-13. All
> 19 first-party runtime hashes matched Blockscout's deployed-bytecode records and all
> 5 listed dependencies had code. Blockscout labels all 19 first-party entries verified:
> 6 fully and 13 partially. 18 main source files match exactly; the remaining
> difference is comment-only. This reconciliation is evidence, not an independent audit.

Network: Robinhood Chain (`chainId 4663`)

Explorer: [robinhoodchain.blockscout.com](https://robinhoodchain.blockscout.com)

Names, tickers, logos and websites can be copied. The full address and chain ID are the contract's
identity.

## Degen LaunchHub

| Component | Address | Public source |
| --- | --- | --- |
| Degen LaunchHub | [`0x7E20…4176`](https://robinhoodchain.blockscout.com/address/0x7E20ef986E5cA961D3fB40eBADd51c27c6274176) | `contracts-hub/src/production/ProductionDegenLaunchHub.sol` |
| Token deployer | [`0x4F03…bBC0`](https://robinhoodchain.blockscout.com/address/0x4F037d19050B8494fa1f65f924Ce0f5F5D96bBC0) | `contracts-hub/src/deployers/DegenHoodTokenV5Deployer.sol` |
| WETH launch module | [`0x851E…C77A`](https://robinhoodchain.blockscout.com/address/0x851EE5c88Ed241A14698518b9C857bb097AcC77A) | `contracts-hub/src/production/ProductionDegenWethModule.sol` |
| SPY launch module | [`0xfd97…2AF4`](https://robinhoodchain.blockscout.com/address/0xfd9780B6bCC855CE00E80cB183D0047ed0112AF4) | `contracts-hub/src/production/ProductionDegenSpyModule.sol` |
| WETH LP locker | [`0x22c5…86d3`](https://robinhoodchain.blockscout.com/address/0x22c51ef3c036006eB7C0505E192f1E1De38D86d3) | `contracts-hub/src/launchhub-v3/DegenV3LpLocker.sol` |
| SPY LP locker | [`0x86E9…87c1`](https://robinhoodchain.blockscout.com/address/0x86E9535d0224Ea890bbeD10aFd2c6157140C87c1) | `contracts-hub/src/launchhub-spy-v3/DegenSpyV3LpLocker.sol` |
| WETH buyback vault | [`0xdf89…5057`](https://robinhoodchain.blockscout.com/address/0xdf894EC4B3d9Dbe30F81334cEeE0a8D667a35057) | `contracts-hub/src/degen/DegenBuybackVault.sol` |
| SPY buyback vault | [`0x9103…a952`](https://robinhoodchain.blockscout.com/address/0x910313C5303FeCf33A2DBB1d945AAD9C26a3a952) | `contracts-hub/src/degen-spy/DegenSpyBuybackVault.sol` |

## $DEGEN and frozen v4

| Component | Address | Public source |
| --- | --- | --- |
| $DEGEN token | [`0x04d5…aDE6`](https://robinhoodchain.blockscout.com/address/0x04d5D8a61DA0b6548B136412843aDBA55EbeaDE6) | `contracts-v4/src/DegenHoodTokenV4.sol` |
| v4 factory | [`0x4999…3a00`](https://robinhoodchain.blockscout.com/address/0x4999B79be94D1E9CadC7a50cbb4E75B81A0B3a00) | `contracts-v4/src/DegenHoodV4Factory.sol` |
| v4 hook | [`0x61C9…30cC`](https://robinhoodchain.blockscout.com/address/0x61C96E7E3E04317A841E8E24630F9d78f98630cC) | `contracts-v4/src/DegenHoodV4HookV2.sol` |
| v4 LP locker | [`0xfEEB…1B92`](https://robinhoodchain.blockscout.com/address/0xfEEB9f1E369A3FCCDd8388B069b5f86300fe1B92) | `contracts-v4/src/DegenHoodV4LpLocker.sol` |
| v4 fee locker | [`0x05dc…7760`](https://robinhoodchain.blockscout.com/address/0x05dcb43fF3FEA906723ADd1e876D004360E47760) | `contracts-v4/src/DegenHoodFeeLocker.sol` |

## Degenetics · DegenHood Degens

| Component | Address | Public source |
| --- | --- | --- |
| DegenHood Degens | [`0xf449…e71b`](https://robinhoodchain.blockscout.com/address/0xf449B45DcF716E3ee679CDdbB87EB3d9ED34e71b) | `contracts-degenetics/src/DegenhoodDegens.sol` |
| Hood Conductor | [`0x800C…E9C8`](https://robinhoodchain.blockscout.com/address/0x800C6304da5752AF135459e4790Bb4b795C5E9C8) | `contracts-degenetics/src/HoodConductor.sol` |
| v4 price source | [`0x39cc…C7C0`](https://robinhoodchain.blockscout.com/address/0x39cc8CEF2Dbc735F5B1cEaD3F6006095Fc84C7C0) | `contracts-degenetics/src/V4PriceSource.sol` |
| LP fee forwarder | [`0xD242…b857`](https://robinhoodchain.blockscout.com/address/0xD2428d2190bc383d9d34706f9BDD591290aab857) | `contracts-degenetics/src/HoodFeeForwarder.sol` |
| Royalty forwarder | [`0x0115…E5C1`](https://robinhoodchain.blockscout.com/address/0x011508A95f4C97F34182676316236901c273E5C1) | `contracts-degenetics/src/HoodFeeForwarder.sol` |
| Fee flusher | [`0xE073…17De`](https://robinhoodchain.blockscout.com/address/0xE0731f4adA23BF193278188Bd3BE2407F56817De) | `contracts-degenetics/src/HoodFeeFlusher.sol` |

## Canonical dependencies

| Component | Address |
| --- | --- |
| Uniswap v4 PoolManager | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |
| Uniswap v4 PositionManager | `0x58daec3116aae6D93017bAAea7749052E8a04fA7` |
| Uniswap Universal Router | `0x8876789976dEcBfCbBbe364623C63652db8C0904` |
| WETH | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` |
| SPY | `0x117cc2133c37B721F49dE2A7a74833232B3B4C0C` |

## Verification procedure

1. Confirm chain ID `4663` from an independent RPC.
2. Resolve code and state at the recorded block and store its hash.
3. Compile the stated public source with the pinned compiler and settings.
4. Compare runtime bytecode, accounting for published immutable values and metadata.
5. Confirm LaunchHub domain/template activation and every configured authority.
6. Link the resulting evidence from the tagged public release.
