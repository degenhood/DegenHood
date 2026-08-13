# Compatibility

## Current package status

`@degenhood/sdk` and `@degenhood/cli` `0.1.x` are **legacy v4-factory tooling**. They prepare and
verify the earlier factory transaction shape and must not be represented as the current production
LaunchHub integration.

The current production Degen LaunchHub is:

| Field | Value |
| --- | --- |
| Chain | Robinhood Chain (`4663`) |
| LaunchHub | `0x7E20ef986E5cA961D3fB40eBADd51c27c6274176` |
| Domain | `0xca7d76493b8150a6f1c7a32d5ea9a94dadfd592b3277657d8216327ffbac33df` |

The canonical workspace contains later LaunchHub helper code, but that alone does not make a public
package production-compatible. The public OpenAPI launch-preparation route still declares the
legacy v4-factory response shape.

## Required before a current LaunchHub release

A new SDK/CLI release may be described as current only when public tests prove:

1. chain, production LaunchHub and domain binding;
2. active production template discovery and exact version binding;
3. request commitment and predicted `…de6` token validation;
4. canonical pool ordering against the selected quote asset;
5. active module and shared token-deployer equivalence;
6. a direct zero-value call to the production LaunchHub;
7. exact calldata equivalence between API, SDK and CLI;
8. rejection of stale, deprecated, substituted or unrecognised templates;
9. isolated package tarballs containing no signing, sending or broadcast primitive;
10. read-only compatibility against the production graph at a recorded block.

Until all gates pass, use the production web interface for current launches. The `0.1.x` packages
remain available for explicitly documented legacy and read-only use and are open to public pull
requests under the repository contribution policy.

## Compatibility labels

| Label | Meaning |
| --- | --- |
| `current` | Proven against the identified production graph and public compatibility suite |
| `legacy` | Retained for an older deployed transaction shape; not the current launch path |
| `candidate` | Implemented or proposed but not yet proven and released |
| `unsupported` | No compatibility or security support is promised |
