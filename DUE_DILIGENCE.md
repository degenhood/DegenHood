# Due diligence

This is the starting point for technical reviewers, integrators and professional counterparties. It
separates observable facts from project claims and records what remains outside the public evidence
set.

## Evidence map

| Question | Primary evidence | Independent check |
| --- | --- | --- |
| What is deployed? | `docs/deployments.md` | Read code and state at the listed chain/address |
| Does public source match? | release manifest and source commit | Compare runtime bytecode and verified explorer source |
| How are launches created? | `contracts-hub/src` and tests | Rebuild and run the LaunchHub test suite |
| Is v4 frozen? | `contracts-v4/src` and deployment record | Inspect deployed bytecode and exposed authorities |
| How does Degenetics work? | `contracts-degenetics/src` and `docs/degenetics.md` | Rebuild, run tests and inspect the six-address deployed graph |
| Where does supply go? | module, token and LP-locker source | Trace launch tests and emitted events |
| Where do fees go? | hook, locker and vault source | Reproduce fee tests and inspect configured recipients |
| Can tooling sign or send? | SDK/CLI source and distribution guards | Inspect package tarballs and run negative tests |
| What does the hosted API do? | OpenAPI contract | Prepare, verify and simulate without trusting its response |
| What can operators change? | governance/authority documentation | Inspect source, immutable values and live state |

## Assurance labels

Public documentation uses these labels consistently:

- **Deployed:** an address exists on the stated chain.
- **Verified source:** explorer-displayed source has been matched to deployed bytecode.
- **Reproduced:** a documented build/test was repeated from the public repository.
- **Security reviewed:** a named scope, commit, reviewer and disposition are publicly available.
- **Frozen:** project policy forbids source changes without a fresh review; it does not imply the
  absence of all on-chain authorities.
- **Candidate:** not represented as deployed or active.

No review should be described as an audit unless the public evidence supports that wording.

## Core protocol facts to verify

Reviewers should independently confirm, for each active template:

1. fixed initial supply and whether any mint path exists;
2. allocation of initial supply into liquidity;
3. whether LP principal can be removed, rescued or transferred;
4. launch fee schedule and every fee destination;
5. creator, token-admin, fee-admin and beneficiary authority lifecycle;
6. template activation, deprecation, pause and emergency-halt powers;
7. token-side burn or dead-address treatment versus `totalSupply` reduction;
8. quote-asset and external-protocol dependencies;
9. transaction target, chain, value and calldata checks in public tooling;
10. discrepancies between product copy, public documentation and deployed behaviour.

## Known limitations and residual risk

- Smart-contract review and tests cannot prove the absence of all defects.
- Permanently locked liquidity does not ensure liquidity depth, price stability or token value.
- A token may be volatile, illiquid, manipulated, copied or misrepresented by third parties.
- Wallets, RPCs, explorers, routers, indexers and quote assets introduce external dependencies.
- Public API availability is not required to verify deployed contracts, but it affects hosted product
  availability.
- Source publication does not grant rights beyond the applicable licence.
- Private operational systems are intentionally outside this repository; their exclusion must not be
  presented as public verification of those systems.
- Degenetics relies on commit/reveal entropy liveness and retains documented admin surfaces; source
  publication does not remove those trust assumptions.

## Public release evidence

Each release should attach or link:

- canonical source commit and public manifest hash;
- deterministic exported file list with SHA-256 hashes;
- contract build/test output and compiler versions;
- SDK/CLI package-content verification;
- secret, licence and dependency scan summaries;
- production-address reconciliation block and timestamp;
- security-review scope and disposition where publication is authorised;
- known differences from the preceding public snapshot.

## Reviewer quick path

```sh
git clone https://github.com/degenhood/DegenHood.git
cd DegenHood

./scripts/verify-public-core.sh
```

The proposed script must be non-interactive, perform no broadcast, require no credential and print
the exact checks it runs. Reviewers can then follow `docs/deployments.md` to compare the build with
Robinhood Chain.

## Contact and disclosures

Security findings belong in private vulnerability reports under [`SECURITY.md`](SECURITY.md).
Commercial, legal or diligence enquiries should use a role address owned by DegenHood; the final
address must be approved before publication.
