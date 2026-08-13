# Security policy

## Report privately

Use [GitHub Security Advisories](https://github.com/degenhood/DegenHood/security/advisories/new)
through private vulnerability reporting instead of a public issue.
Do not publish a vulnerability, exploit, credential, funded-wallet signature or sensitive personal
data in an issue, pull request, discussion, social post or on-chain message.

Include:

- affected component and public commit or deployed address;
- realistic impact and preconditions;
- minimal reproduction using local simulation or accounts you control;
- suggested mitigation, if known;
- a safe contact method for coordinated follow-up.

## Public scope

In scope:

- DegenHood-authored production contract source published under `contracts-hub/src` and
  `contracts-v4/src`;
- Degenetics contract source published under `contracts-degenetics/src`;
- `@degenhood/sdk`, `@degenhood/cli` and the public OpenAPI contract;
- failures that cross the documented non-custodial boundary;
- material differences between public source, wallet-visible intent and deployed behaviour.

Private infrastructure is not available for unauthorised testing. Third-party wallets, protocols,
RPCs, explorers and dependencies should normally be reported to their maintainers unless the flaw
is caused by DegenHood integration code.

## Safe research

- Prefer local chains, forks and simulations.
- Use only accounts, assets and data you control.
- Do not access another user's data or funds.
- Do not degrade availability, evade controls, spam services or test production without written
  permission.
- Stop before a test could move funds, expose personal data or materially affect another user.

We will acknowledge reproducible, good-faith reports as capacity permits and coordinate remediation
and disclosure. Submission does not create a bounty entitlement, contractual obligation or
guaranteed response time.

## Supported versions

Security fixes target the current public `main` release and deployed production contracts where a
remediation path exists. Older prereleases and unlisted deployments may be unsupported.
