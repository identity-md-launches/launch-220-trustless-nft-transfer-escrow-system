import { AbiCoder, getAddress, keccak256, ZeroAddress } from './vendor/ethers-6.13.5.min.mjs';
export const ASSET_TYPE = 'tuple(uint8 kind,address token,uint256 id,uint256 amount)[]';
export function uint(value, label = 'Value', positive = false) {
  if (!/^(0|[1-9][0-9]*)$/.test(String(value))) throw Error(`${label} must be a whole decimal integer.`);
  const n = BigInt(value);
  if (n >= 1n << 256n || (positive && n === 0n)) throw Error(`${label} is out of range.`);
  return n.toString();
}
export function address(value) {
  const result = getAddress(String(value).trim());
  if (result === ZeroAddress) throw Error('The zero address is not allowed.');
  return result;
}
export function normalizeAsset(asset) {
  const kind = Number(asset.kind);
  if (kind !== 0 && kind !== 1) throw Error('Choose ERC-721 or ERC-20.');
  const result = { kind, token: address(asset.token), id: uint(asset.id, 'Token ID'), amount: uint(asset.amount, 'Amount', true) };
  if (kind === 0 && result.amount !== '1') throw Error('Each NFT must have amount 1.');
  if (kind === 1 && result.id !== '0') throw Error('ERC-20 token ID must be zero.');
  return result;
}
export function normalizeTerms(offered, requested) {
  const all = [offered, requested].map(items => {
    if (!Array.isArray(items) || items.length < 1 || items.length > 16) throw Error('Use 1–16 assets on each side.');
    return items.map(normalizeAsset);
  });
  if (all[0].some(a => a.kind !== 0)) throw Error('The sender offers ERC-721 NFTs only.');
  const seen = new Set();
  for (const a of all.flat()) {
    const key = `${a.kind}:${a.token.toLowerCase()}:${a.id}`;
    if (seen.has(key)) throw Error('An asset appears more than once. Combine ERC-20 amounts.');
    seen.add(key);
  }
  return { offered: all[0], requested: all[1] };
}
export function hashTerms(offered, requested) {
  return keccak256(AbiCoder.defaultAbiCoder().encode([ASSET_TYPE, ASSET_TYPE], [offered, requested]));
}
export function txHash(value) {
  if (!/^0x[0-9a-fA-F]{64}$/.test(value)) throw Error('Enter the creation transaction hash (0x + 64 hex characters).');
  return value;
}
export function shareLink(base, chainId, contract, transaction) {
  const url = new URL(base); url.hash = new URLSearchParams({ chain: uint(chainId, 'Chain ID', true), contract: address(contract), tx: txHash(transaction) }).toString();
  return url.href;
}
export function readShare(hash) {
  const params = new URLSearchParams(hash.replace(/^#/, ''));
  if (!params.has('tx')) return null;
  return { chainId: uint(params.get('chain'), 'Chain ID', true), contract: address(params.get('contract')), transaction: txHash(params.get('tx')) };
}
export function offerState(offer, account, chainTimestamp) {
  const open = Number(offer.status) === 1;
  const expired = BigInt(chainTimestamp) >= BigInt(offer.expiresAt);
  const same = value => value.toLowerCase() === account.toLowerCase();
  return {
    label: !open ? ['Missing', 'Open', 'Filled', 'Cancelled'][Number(offer.status)] : expired ? 'Expired · reclaim available' : 'Open',
    canFill: open && !expired && same(offer.taker), canCancel: open && same(offer.maker),
  };
}
