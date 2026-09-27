# Vendored dependency provenance

All required libraries are ordinary files; there are no git submodules or runtime CDN imports.

| Component | Version / upstream | Delivered files | License |
| --- | --- | --- | --- |
| forge-std | [v1.9.7](https://github.com/foundry-rs/forge-std/tree/v1.9.7) | `lib/forge-std/src/` and license files | Apache-2.0 / MIT |
| ethers browser ESM bundle | [6.13.5](https://github.com/ethers-io/ethers.js/tree/v6.13.5) | `frontend/vendor/ethers-6.13.5.min.mjs` | MIT; included alongside bundle |
| Official Solidity compiler, Linux x86-64 | [0.8.26, commit 8a97fa7a](https://github.com/ethereum/solidity/releases/tag/v0.8.26) | `toolchain/svm/0.8.26/solc-0.8.26` | GPL-3.0; license included; corresponding source at linked tag |

The forge-std archive was obtained from `https://codeload.github.com/foundry-rs/forge-std/tar.gz/refs/tags/v1.9.7`; only `src/` and license files are included. ethers was obtained from `https://cdn.jsdelivr.net/npm/ethers@6.13.5/dist/ethers.min.js` and renamed `.mjs` without changing bytes. The native compiler was installed by Foundry's normal version manager, then kept in its standard cache layout for offline verification. It is not a script or custom compiler.

`toolchain/SHA256SUMS` records the compiler and browser bundle digests. Verify from the repository root with `sha256sum -c toolchain/SHA256SUMS`. Foundry, Anvil, Node.js and Python are host tools, not application dependencies. No external package manager is used by build/test/serve scripts.

The original contract sources are MIT licensed; see `LICENSE`.
