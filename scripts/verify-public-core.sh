#!/usr/bin/env bash
set -euo pipefail

repository_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repository_dir}"

git diff --check

node scripts/verify-public-disclosure.mjs .
node --test test/public*.test.js
node --test test/developerDistribution.test.js
node scripts/verify-package-release.mjs

npm test --prefix packages/sdk
npm test --prefix packages/cli
