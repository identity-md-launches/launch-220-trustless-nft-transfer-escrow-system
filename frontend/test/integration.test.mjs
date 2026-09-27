import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { spawn } from 'node:child_process';
import { createServer } from 'node:net';
import { JsonRpcProvider, ContractFactory, Contract } from '../vendor/ethers-6.13.5.min.mjs';
import { SwapClient } from '../client.mjs';
const artifact = file => JSON.parse(readFileSync(new URL(`../../out/${file}`, import.meta.url)));
const frontendArtifact = JSON.parse(readFileSync(new URL('../contract.json', import.meta.url)));
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
test('offline local chain: browser client creates, reloads, fills, rejects and reclaims', { timeout: 60000 }, async () => {
  const tempServer = createServer(); await new Promise(resolve => tempServer.listen(0, '127.0.0.1', resolve));
  const port = tempServer.address().port; await new Promise(resolve => tempServer.close(resolve));
  const anvil = spawn('anvil', ['--silent', '--host', '127.0.0.1', '--port', String(port)], { stdio: 'ignore' });
  let launchError; anvil.on('error', e => { launchError = e; });
  const provider = new JsonRpcProvider(`http://127.0.0.1:${port}`, 31337, { cacheTimeout: -1, batchMaxCount: 1 });
  provider.pollingInterval = 30;
  try {
    for (let i = 0; i < 100; i++) {
      if (launchError) throw launchError;
      try { const res = await fetch(`http://127.0.0.1:${port}`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' }); if (res.ok) break; } catch {}
      await delay(30);
    }
    const maker = await provider.getSigner(0), taker = await provider.getSigner(1), third = await provider.getSigner(2);
    const deploy = async path => { const a = artifact(path); const c = await new ContractFactory(a.abi, a.bytecode.object, maker).deploy(); await c.waitForDeployment(); return c; };
    const swap = await deploy('NFTSwap.sol/NFTSwap.json');
    const nft = await deploy('Assets.sol/Mock721.json'); const coin = await deploy('Assets.sol/Mock20.json');
    const config = { chainId: '31337', contract: await swap.getAddress() };
    const sender = await new SwapClient(provider, maker, config, frontendArtifact).ready();
    const receiver = await new SwapClient(provider, taker, config, frontendArtifact).ready();
    const outsider = await new SwapClient(provider, third, config, frontendArtifact).ready();
    await assert.rejects(new SwapClient(provider, maker, { ...config, chainId: '1' }, frontendArtifact).ready(), /Switch your wallet/);
    await assert.rejects(new SwapClient(provider, maker, { ...config, contract: await coin.getAddress() }, frontendArtifact).ready(), /expected NFTSwap/);
    await (await nft.mint(sender.account, 0)).wait(); await (await nft.mint(sender.account, 1)).wait();
    await (await coin.mint(receiver.account, 1000)).wait();
    const offered = [{ kind: 0, token: await nft.getAddress(), id: '0', amount: '1' }];
    const requested = [{ kind: 1, token: await coin.getAddress(), id: '0', amount: '100' }];
    const offer = await sender.create(receiver.account, offered, requested);
    assert.equal(await nft.ownerOf(0), config.contract);
    assert.equal(offer.id, '1'); assert.equal(offer.status, 1);
    const loaded = await receiver.load(offer.transaction);
    assert.equal(loaded.offered[0].id, '0'); assert.equal(loaded.requested[0].amount, '100');
    await assert.rejects(outsider.fill(loaded), /Only the named receiver/);
    await assert.rejects(receiver.cancel(loaded), /Only the sender/);
    const altered = { ...loaded, requested: [{ ...requested[0], amount: '101' }] };
    await assert.rejects(receiver.fill(altered), /do not match/);
    await receiver.fill(loaded);
    assert.equal(await nft.ownerOf(0), receiver.account);
    assert.equal(await coin.balanceOf(sender.account), 100n);
    assert.equal(await coin.allowance(receiver.account, config.contract), 0n);
    assert.equal((await sender.load(offer.transaction)).status, 2);
    await assert.rejects(receiver.fill(loaded), /Only the named receiver/);
    const second = await sender.create(receiver.account, [{ ...offered[0], id: '1' }], requested);
    await provider.send('evm_increaseTime', [1800]); await provider.send('evm_mine', []);
    await assert.rejects(receiver.fill(second), /Only the named receiver/);
    await sender.cancel(second); assert.equal(await nft.ownerOf(1), sender.account);
    assert.equal((await sender.load(second.transaction)).status, 3);
    await assert.rejects(sender.load(`0x${'00'.repeat(32)}`), /missing/);
    console.log('Client verified runtime, chain, exact approvals, receipt recovery, settlement, expiry and refund.');
  } finally { provider.destroy(); anvil.kill('SIGTERM'); }
});
