import { Contract, getAddress, keccak256 } from './vendor/ethers-6.13.5.min.mjs';
import { address, normalizeTerms, hashTerms, txHash, uint, offerState } from './model.mjs';
const NFT_ABI = ['function ownerOf(uint256) view returns (address)', 'function getApproved(uint256) view returns (address)', 'function isApprovedForAll(address,address) view returns (bool)', 'function approve(address,uint256)'];
const COIN_ABI = ['function allowance(address,address) view returns (uint256)', 'function balanceOf(address) view returns (uint256)', 'function approve(address,uint256) returns (bool)'];
export class SwapClient {
  constructor(provider, signer, config, artifact, progress = () => {}) {
    this.provider = provider; this.signer = signer;
    this.chainId = uint(config.chainId, 'Chain ID', true); this.address = address(config.contract);
    this.artifact = artifact; this.progress = progress;
    this.contract = new Contract(this.address, artifact.abi, signer);
  }
  async ready() {
    await this.assertSession();
    const code = await this.provider.getCode(this.address);
    if (code === '0x' || keccak256(code) !== this.artifact.runtimeHash) throw Error('This address does not contain the expected NFTSwap contract. Check the network and address.');
    return this;
  }
  async assertSession() {
    // Request the live wallet chain rather than relying on a cached provider network.
    const chain = BigInt(await this.provider.send('eth_chainId', []));
    if (chain !== BigInt(this.chainId)) throw Error(`Switch your wallet to chain ${this.chainId}, then reconnect.`);
    this.account = getAddress(await this.signer.getAddress());
    const accounts = await this.provider.send('eth_accounts', []);
    if (!accounts.some(a => a.toLowerCase() === this.account.toLowerCase())) throw Error('The connected wallet account changed. Reconnect.');
  }
  async send(method, args, label) {
    await this.assertSession(); this.progress(`${label}: confirm in your wallet.`);
    await method.estimateGas(...args);
    const transaction = await method(...args);
    this.progress(`${label}: waiting for confirmation. ${transaction.hash}`);
    const receipt = await transaction.wait();
    if (!receipt || receipt.status !== 1) throw Error(`${label} failed.`);
    return receipt;
  }
  async approveAssets(assets) {
    for (const a of assets) {
      await this.assertSession();
      if (a.kind === 0) {
        const nft = new Contract(a.token, NFT_ABI, this.signer);
        if (getAddress(await nft.ownerOf(a.id)) !== this.account) throw Error(`Your account does not own ${a.token} #${a.id}.`);
        if (getAddress(await nft.getApproved(a.id)) !== this.address && !await nft.isApprovedForAll(this.account, this.address)) {
          await this.send(nft.approve, [this.address, a.id], `Approve NFT #${a.id}`);
        }
      } else {
        const coin = new Contract(a.token, COIN_ABI, this.signer);
        if (await coin.balanceOf(this.account) < BigInt(a.amount)) throw Error(`Insufficient token balance at ${a.token}.`);
        const allowance = await coin.allowance(this.account, this.address);
        if (allowance < BigInt(a.amount)) {
          if (allowance !== 0n) await this.send(coin.approve, [this.address, 0], 'Reset previous token allowance');
          await this.send(coin.approve, [this.address, a.amount], `Approve ${a.amount} minor units`);
        }
      }
    }
  }
  async create(takerInput, offeredInput, requestedInput) {
    const taker = address(takerInput); const terms = normalizeTerms(offeredInput, requestedInput);
    await this.assertSession();
    if (taker === this.account || taker === this.address) throw Error('Choose a different receiver wallet.');
    await this.approveAssets(terms.offered);
    const receipt = await this.send(this.contract.createOffer, [taker, terms.offered, terms.requested], 'Create escrow');
    return this.load(receipt.hash);
  }
  async load(transactionHash) {
    await this.assertSession();
    const receipt = await this.provider.getTransactionReceipt(txHash(transactionHash));
    if (!receipt || receipt.status !== 1) throw Error('Creation transaction is missing, pending, or failed.');
    const events = receipt.logs.filter(log => log.address.toLowerCase() === this.address.toLowerCase()).map(log => {
      try { return this.contract.interface.parseLog(log); } catch { return null; }
    }).filter(log => log?.name === 'OfferCreated');
    if (events.length !== 1) throw Error('Expected exactly one offer from this contract in the creation receipt.');
    const e = events[0].args;
    const terms = normalizeTerms(e.offered, e.requested);
    const offer = { id: e.offerId.toString(), maker: e.maker, taker: e.taker, expiresAt: e.expiresAt.toString(), ...terms, transaction: receipt.hash };
    await this.refresh(offer);
    return offer;
  }
  async refresh(offer) {
    await this.assertSession();
    const state = await this.contract.offers(offer.id);
    if (state.termsHash !== hashTerms(offer.offered, offer.requested) || state.maker !== offer.maker || state.taker !== offer.taker || state.expiresAt.toString() !== offer.expiresAt) throw Error('Offer details do not match on-chain storage.');
    offer.status = Number(state.status);
    const block = await this.provider.getBlock('latest');
    offer.chainTimestamp = block.timestamp;
    return offerState(offer, this.account, block.timestamp);
  }
  async fill(offer) {
    if (!(await this.refresh(offer)).canFill) throw Error('Only the named receiver can fill an open, unexpired offer.');
    await this.approveAssets(offer.requested);
    if (!(await this.refresh(offer)).canFill) throw Error('The offer expired or closed while approving assets.');
    return this.send(this.contract.fillOffer, [offer.id, offer.offered, offer.requested], 'Settle swap');
  }
  async cancel(offer) {
    if (!(await this.refresh(offer)).canCancel) throw Error('Only the sender can reclaim an open offer.');
    return this.send(this.contract.cancelOffer, [offer.id, offer.offered, offer.requested], 'Cancel and reclaim');
  }
}
