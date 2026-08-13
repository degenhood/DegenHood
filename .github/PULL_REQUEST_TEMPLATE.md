## Problem

<!-- What user, integrator, or reviewer problem does this solve? -->

## Change

<!-- What changed, and what deliberately did not? Keep this PR to one concern. -->

## Tests run

```text
./scripts/verify-public-core.sh
```

## Review declarations

- [ ] I assessed the security and trust-boundary impact.
- [ ] I documented any SDK, CLI, API, contract, or deployment compatibility impact.
- [ ] I confirmed the licensing and provenance of every new dependency, asset, and copied source.
- [ ] I did not add secrets, wallet material, production data, signing, broadcast, or fund movement.
- [ ] Every commit includes `Signed-off-by: Name <email>` under the DCO 1.1.

## Publication boundary

The private canonical repository remains the source of truth. An accepted public change is ported
there with authorship preserved, independently verified, and returned only in a verified public
snapshot. Approval of this pull request does not itself deploy contracts or publish production code.
