# Contributing to DegenHood developer tooling

Thanks for helping improve the DegenHood SDK, CLI, examples, specification, or agent workflow.

## Before opening a change

- Use a focused branch and keep each pull request to one coherent concern.
- Report security-sensitive findings through [private vulnerability reporting](SECURITY.md), not a
  public pull request.
- Do not include secrets, wallet material, production state, generated artifacts, or personal data.
- Preserve the non-custodial boundary: tooling must not accept private keys, sign, send, broadcast,
  deploy, sponsor gas, or move funds.
- Keep the repository limited to the public developer surface.

## Local verification

```sh
npm ci --prefix packages/sdk
npm ci --prefix packages/cli
npm test
npm run verify:packages
```

Add a focused regression test before changing behavior. Keep package tarball contents within the
explicit allowlist in `scripts/verify-package-release.mjs`.

## Pull requests

Explain:

- what changed and why;
- developer impact;
- tests executed;
- security considerations; and
- anything intentionally deferred.

By contributing, you agree that your contribution is licensed under the repository's MIT License.
