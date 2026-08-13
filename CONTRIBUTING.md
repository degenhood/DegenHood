# Contributing

DegenHood welcomes focused bug fixes, tests, documentation improvements and integration feedback
through a public pull request.
The private canonical repository remains the source of truth, so accepted public changes are ported
to canonical and later returned through a verified public snapshot.

## Before opening a change

- Search existing issues and keep the pull request to one coherent concern.
- Report security findings privately under [`SECURITY.md`](SECURITY.md).
- Do not include secrets, private endpoints, wallet material, production data or generated output.
- Add a regression test before changing behaviour.
- Do not add signing, sending, broadcast, deployment or fund-movement capability to public tooling.
- Do not change frozen contracts without an agreed fresh-review scope.

## Pull request contract

Explain:

1. the user, integrator or reviewer problem;
2. what changed and what deliberately did not;
3. tests executed with exact commands;
4. security, compatibility and licensing impact;
5. any change to public claims, addresses or trust assumptions.

Use the [Developer Certificate of Origin 1.1](LICENSES/LicenseRef-DCO-1.1.txt) sign-off
(`Signed-off-by: Name <email>`) for every commit. Code
contributions are submitted under MIT and documentation contributions under CC BY 4.0. Do not add
brand artwork unless the rights owner has approved its public terms.

## Verification

```sh
./scripts/verify-public-core.sh
```

Run the smallest relevant component suite during development and the full public-core check before
requesting review.

The complete canonical-port and verified-snapshot flow is documented in
[`docs/publication-process.md`](docs/publication-process.md).

## Contract changes

Deployed bytecode cannot be changed by editing this repository. Any proposal affecting future
contract code must identify changed invariants, authority, external calls, value flows and deployment
assumptions and requires independent security review before production use.
