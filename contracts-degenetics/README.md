# Degenetics deployed contracts

This project is assembled from exact explorer-matched Git blobs from the private canonical
Degenetics repository. The deployed graph was compiled over more than one source commit, so each
file retains its own provenance in `PUBLIC-MANIFEST.json` and
`SOURCE-MAP.json`.

Included contracts:

- `DegenhoodDegens` — backed 1,000-pack ERC-721 and activated-holder distributor;
- `HoodConductor` — commit/reveal entropy coordinator;
- `V4PriceSource` — immutable DEGEN/WETH v4 pool price reader;
- `HoodFeeForwarder` — WETH unwrap and tagged reward routing;
- `HoodFeeFlusher` — permissionless harvest/claim/forward composition.

Operator deployment scripts, keeper scripts, seed material and operational configuration are not
part of the public source boundary.

## Verify

```sh
./scripts/install-dependencies.sh
forge fmt --check
forge build
forge test
```

The dependency installer checks out exact commits. It does not sign, broadcast or read wallet
configuration.
