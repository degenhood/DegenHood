# Public contribution and publication process

The private canonical repository is the source of truth. This public repository is a deterministic,
reviewable projection of an approved canonical commit; it is not a bidirectional mirror and it does
not expose private infrastructure or operational history.

## Contribution flow

1. A contributor opens a focused public pull request with DCO sign-off and passing public checks.
2. Maintainers review the interface, provenance, compatibility, security, licensing, and test scope.
3. If accepted, a maintainer ports the change into the private canonical repository while preserving
   the original author and public pull-request reference.
4. The canonical version receives its normal tests and any additional security review required by
   the affected component.
5. The deny-by-default exporter reads an immutable canonical commit and creates a candidate snapshot
   with source commit, policy hash, path list, Git object IDs, and SHA-256 file hashes.
6. A public release pull request presents the complete snapshot diff and verification evidence.
7. Required checks and human approval complete before the release pull request reaches `main`.

Never merge a contribution directly from its public feature branch into public `main`. The returned
snapshot proves that the accepted change passed through the canonical security and release boundary.

## Required repository controls

Before the first release, an administrator must configure and verify these GitHub settings:

- branch protection or repository rulesets for `main`, requiring pull requests, CI and CodeQL;
- dismissal of stale approvals and review from CODEOWNERS for protected paths;
- no force pushes or branch deletion, and restricted bypass rights;
- private vulnerability reporting and GitHub Security Advisories;
- secret scanning, push protection, dependency graph and Dependabot alerts;
- tag/release protection and human approval of the exact exported manifest;
- Actions restricted to reviewed, commit-pinned actions with read-only default permissions.

Settings are external state and cannot be established by files in a snapshot. Record a dated settings
review in the canonical release evidence before publication.

## Release evidence

Every public release should identify the immutable canonical commit, exporter policy hash, public
commit, manifest digest, dependency/SBOM evidence, production reconciliation block, test commands,
and the security, product, legal, and operator approvers. No publication step authorises contract
deployment, transaction broadcast, signing, or fund movement.
