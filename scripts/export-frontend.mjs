import { readFileSync, writeFileSync } from 'node:fs';
import { keccak256 } from '../frontend/vendor/ethers-6.13.5.min.mjs';
const artifact = JSON.parse(readFileSync(new URL('../out/NFTSwap.sol/NFTSwap.json', import.meta.url)));
const generated = { abi: artifact.abi, runtimeHash: keccak256(artifact.deployedBytecode.object) };
writeFileSync(new URL('../frontend/contract.json', import.meta.url), JSON.stringify(generated, null, 2) + '\n');
console.log(`Exported NFTSwap ABI and runtime hash ${generated.runtimeHash}`);
