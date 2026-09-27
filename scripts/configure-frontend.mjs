// Writes a reviewed deployment configuration; never deploys or sends a transaction.
import { writeFileSync } from 'node:fs';
import { address, uint } from '../frontend/model.mjs';
const [chain, contract] = process.argv.slice(2);
if (!chain || !contract) throw Error('Usage: node scripts/configure-frontend.mjs <chain-id> <deployed-NFTSwap-address>');
const config = { chainId: uint(chain, 'Chain ID', true), contract: address(contract), deploymentStatus: 'Verify this chain and escrow address against the published deployment record before connecting.' };
writeFileSync(new URL('../frontend/config.json', import.meta.url), JSON.stringify(config, null, 2) + '\n');
console.log(`Configured chain ${config.chainId}, NFTSwap ${config.contract}. This does not deploy or verify a contract.`);
