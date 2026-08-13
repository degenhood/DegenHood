# Third-party notices

DegenHood is an independent project. Its first-party licence does not replace or modify the terms
that apply to third-party dependencies. Exact commits and package lockfiles are the authoritative
version record.

## Solidity dependencies

| Dependency | Public use | Licence |
| --- | --- | --- |
| OpenZeppelin Contracts | ERC-20, ERC-721, safety and utility primitives | MIT |
| Uniswap v4 core and periphery | pool, hook and liquidity-position interfaces and implementations | Business Source License 1.1 and other path-specific upstream terms |
| Uniswap Permit2 | token approval and transfer primitives | MIT |
| Uniswap Universal Router | routing integration | GPL-3.0-or-later and other path-specific upstream terms |
| Foundry forge-std | contract test framework | MIT or Apache-2.0 |

Degenetics pins OpenZeppelin Contracts and forge-std to exact Git commits in
`public-repository/degenetics-manifest.json`. The v4 project pins its Git dependencies as submodules.
Review the licence and notice nearest each dependency before redistribution.

## JavaScript dependencies

The SDK and CLI lockfiles resolve their production dependency graph, principally including `viem`
and its cryptographic and encoding dependencies. Each package remains governed by the licence in its
resolved archive. Release evidence should include CycloneDX SBOMs and a licence-metadata inventory.

The hosted product dependency graph is outside this repository. Its exclusion is intentional and is
not a statement about the licences or security of that private product implementation.

Third-party names and marks identify interoperability or dependency provenance only. They do not
imply sponsorship, endorsement or affiliation.
