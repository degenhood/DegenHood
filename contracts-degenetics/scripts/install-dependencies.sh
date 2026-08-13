#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

install_pinned_dependency() {
  local repository="$1"
  local commit="$2"
  local destination="$3"

  if [[ -d "${destination}/.git" ]]; then
    test "$(git -C "${destination}" rev-parse HEAD)" = "${commit}" || {
      echo "unexpected dependency commit at ${destination}" >&2
      exit 1
    }
    return
  fi
  test ! -e "${destination}" || {
    echo "dependency destination already exists: ${destination}" >&2
    exit 1
  }
  git clone --filter=blob:none --no-checkout "${repository}" "${destination}"
  git -C "${destination}" checkout --detach "${commit}"
  test "$(git -C "${destination}" rev-parse HEAD)" = "${commit}"
}

mkdir -p "${project_dir}/lib"
install_pinned_dependency \
  "https://github.com/foundry-rs/forge-std.git" \
  "bf647bd6046f2f7da30d0c2bf435e5c76a780c1b" \
  "${project_dir}/lib/forge-std"
install_pinned_dependency \
  "https://github.com/OpenZeppelin/openzeppelin-contracts.git" \
  "dbb6104ce834628e473d2173bbc9d47f81a9eec3" \
  "${project_dir}/lib/openzeppelin-contracts"
