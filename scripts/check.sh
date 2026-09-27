#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Foundry's normal SVM cache layout, with the official compiler already vendored.
export XDG_DATA_HOME="$PWD/toolchain"
sha256sum -c toolchain/SHA256SUMS
forge build --offline
forge test --offline
forge fmt --check
node scripts/export-frontend.mjs
node --test frontend/test/*.test.mjs
