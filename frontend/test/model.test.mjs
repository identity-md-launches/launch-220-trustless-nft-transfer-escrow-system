import test from 'node:test';
import assert from 'node:assert/strict';
import { normalizeTerms, uint, hashTerms, readShare, shareLink, offerState } from '../model.mjs';
const a = '0x0000000000000000000000000000000000000001';
const b = '0x0000000000000000000000000000000000000002';
const offered = [{ kind: 0, token: a, id: '9007199254740993', amount: '1' }];
const requested = [{ kind: 1, token: b, id: '0', amount: '1000000000000000000' }];
test('retains integer precision and rejects unsafe inputs', () => {
  assert.equal(normalizeTerms(offered, requested).offered[0].id, '9007199254740993');
  for (const input of ['-1', '1.1', '1e18', '', '00', (1n << 256n).toString()]) assert.throws(() => uint(input));
});
test('exact terms reject duplicates, invalid quantities and missing baskets', () => {
  assert.throws(() => normalizeTerms([], requested));
  assert.throws(() => normalizeTerms(offered, [...requested, ...requested]));
  assert.throws(() => normalizeTerms(offered, offered));
  assert.throws(() => normalizeTerms([{ ...offered[0], amount: '2' }], requested));
  assert.throws(() => normalizeTerms(offered, [{ ...requested[0], amount: '0' }]));
  assert.throws(() => normalizeTerms(offered, [{ ...requested[0], id: '2' }]));
  assert.throws(() => normalizeTerms(requested, requested));
  assert.throws(() => normalizeTerms(Array(17).fill(offered[0]), requested));
  assert.notEqual(hashTerms(offered, requested), hashTerms(offered, [{ ...requested[0], amount: '1' }]));
});
test('share links retain chain, contract and receipt without arbitrary markup', () => {
  const transaction = `0x${'ab'.repeat(32)}`;
  const url = shareLink('https://example.com/index.html', '11155111', a, transaction);
  assert.deepEqual(readShare(new URL(url).hash), { chainId: '11155111', contract: a, transaction });
  assert.throws(() => readShare('#chain=1&contract=javascript:bad&tx=bad'));
});
test('role checks and exclusive expiration boundary', () => {
  const offer = { maker: a, taker: b, expiresAt: '1800', status: 1 };
  assert.equal(offerState(offer, b, 1799).canFill, true);
  assert.equal(offerState(offer, b, 1800).canFill, false);
  assert.equal(offerState(offer, a, 9999).canCancel, true);
  assert.equal(offerState(offer, a, 1).canFill, false);
  assert.equal(offerState({ ...offer, status: 2 }, a, 1).canCancel, false);
});
