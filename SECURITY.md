# Security policy

## Reporting a vulnerability

Please send suspected vulnerabilities through GitHub's private vulnerability reporting:

1. Open this repository's **Security** tab.
2. Select **Advisories**.
3. Select **Report a vulnerability**.
4. Include the affected package or file, reproducible impact, and the smallest safe proof of
   concept.

Use [GitHub Security Advisories](https://github.com/degenhood/DegenHood/security/advisories/new)
instead of a public issue, discussion, pull request, social post, or onchain message.

Do not include real private keys, seed phrases, access tokens, database credentials, funded-wallet
signatures, or unnecessary personal data. Use disposable test accounts and redact secrets from
logs.

## Scope

This repository's security scope is:

- `@degenhood/sdk`;
- `@degenhood/cli`;
- the public OpenAPI specification and examples;
- the public launch-preparation agent skill;
- violations of the documented non-custodial boundary; and
- material discrepancies between verified calldata and wallet-visible intent.

Third-party protocols, wallets, RPC providers, block explorers, and dependencies should be
reported to their maintainers unless the issue is caused by this repository's integration code.

## Safe research

- Use local simulations or accounts you control.
- Do not access other users' data or funds.
- Do not degrade public services, spam endpoints, or test against production without written
  permission.
- Stop when a test could move funds, sign for another party, expose personal data, or affect
  availability.

We will acknowledge good-faith reports as capacity permits, investigate reproducible impact, and
coordinate remediation and disclosure. Submission does not create a contractual obligation,
bounty entitlement, or guaranteed response time.

## Supported versions

Security fixes target the current default branch and the latest stable package versions.
