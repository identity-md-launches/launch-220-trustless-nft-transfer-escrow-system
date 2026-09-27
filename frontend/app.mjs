import { BrowserProvider } from './vendor/ethers-6.13.5.min.mjs';
import { SwapClient } from './client.mjs';
import { shareLink, readShare, offerState } from './model.mjs';
const $ = id => document.getElementById(id);
let client, offer, artifact, busy = false, epoch = 0, lastRefresh = 0;
let saved = [];
try { saved = JSON.parse(localStorage.getItem('pairwise.offers') || '[]'); if (!Array.isArray(saved)) saved = []; } catch { /* Storage is optional. */ }
function message(text, error = false) {
  $('message').textContent = text;
  document.querySelector('.feedback').classList.toggle('error', error);
}
function updateButtons() {
  const connected = !!client;
  const estimatedTime = offer ? Number(offer.chainTimestamp) + Math.floor((Date.now() - lastRefresh) / 1000) : 0;
  const state = offer && connected ? offerState(offer, client.account, estimatedTime) : {};
  $('create').disabled = busy || !connected || !$('confirm-create').checked;
  $('load').disabled = busy || !connected;
  $('fill').disabled = busy || !state.canFill || !$('confirm-fill').checked;
  $('cancel').disabled = busy || !state.canCancel;
  $('refresh').disabled = busy || !connected || !offer;
  for (const id of ['connection-fields', 'create-fields', 'load-fields', 'action-fields']) $(id).disabled = busy;
  if (offer) {
    const remaining = Math.max(0, Number(offer.expiresAt) - estimatedTime);
    $('countdown').textContent = Number(offer.status) !== 1 ? 'Exchange closed' : remaining === 0 ? 'Deadline reached · sender can reclaim' : `≈ ${Math.floor(remaining / 60)}:${String(remaining % 60).padStart(2, '0')} remaining`;
    if (state.label) $('offer-status').textContent = state.label;
  }
}
async function act(task) {
  if (busy) return;
  busy = true; updateButtons();
  try { await task(); } catch (error) {
    message(error.shortMessage || error.reason || error.message || 'The wallet request failed.', true);
  } finally { busy = false; updateButtons(); }
}
function disconnect() {
  ++epoch; client = null;
  $('network-status').textContent = 'Reconnect required';
  $('account').textContent = 'Network or account changed. Verify settings and reconnect.';
  updateButtons();
}
function addAsset(container, kind = '0', fixedNFT = false) {
  if ($(container).children.length >= 16) return message('A basket supports at most 16 assets.', true);
  const node = $('asset-template').content.firstElementChild.cloneNode(true);
  const select = node.querySelector('.kind'); select.value = kind; select.disabled = fixedNFT;
  const label = node.querySelector('.value-label span');
  const update = () => { label.textContent = select.value === '0' ? 'Token ID' : 'Amount (minor units)'; node.querySelector('.value').value = ''; };
  select.addEventListener('change', update); update();
  node.querySelector('.remove').addEventListener('click', () => { node.remove(); $('confirm-create').checked = false; updateButtons(); });
  $(container).append(node);
}
function basket(id) {
  return [...$(id).children].map(node => {
    const kind = Number(node.querySelector('.kind').value), value = node.querySelector('.value').value.trim();
    return { kind, token: node.querySelector('.token').value.trim(), id: kind === 0 ? value : '0', amount: kind === 0 ? '1' : value };
  });
}
function renderAssets(id, assets) {
  $(id).replaceChildren();
  for (const asset of assets) {
    const li = document.createElement('li'), strong = document.createElement('strong'), text = document.createElement('span');
    strong.textContent = asset.kind === 0 ? `ERC-721 · Token #${asset.id}` : `ERC-20 · ${asset.amount} minor units`;
    text.textContent = asset.token; text.className = 'mono'; li.append(strong, text); $(id).append(li);
  }
}
function renderOffer() {
  $('offer').hidden = false; $('empty-offer').hidden = true; $('offer-title').textContent = `Offer #${offer.id}`;
  $('offer-maker').textContent = offer.maker; $('offer-taker').textContent = offer.taker;
  $('offer-expiry').textContent = new Date(Number(offer.expiresAt) * 1000).toUTCString();
  renderAssets('offer-offered', offer.offered); renderAssets('offer-requested', offer.requested);
  $('creation-tx').value = offer.transaction;
  $('share').value = shareLink(location.href, client.chainId, client.address, offer.transaction);
  $('confirm-fill').checked = false; lastRefresh = Date.now();
  const item = { chainId: client.chainId, contract: client.address, transaction: offer.transaction };
  saved = [item, ...saved.filter(s => s.transaction !== item.transaction)].slice(0, 30);
  try { localStorage.setItem('pairwise.offers', JSON.stringify(saved)); } catch { /* Receipt is still shareable. */ }
  renderHistory(); updateButtons();
}
function renderHistory() {
  $('history').replaceChildren();
  for (const item of saved) {
    if (!item || typeof item.transaction !== 'string') continue;
    const li = document.createElement('li'), button = document.createElement('button');
    button.textContent = `Chain ${item.chainId} · ${item.transaction}`;
    button.addEventListener('click', () => act(async () => {
      if (!client || client.chainId !== item.chainId || client.address.toLowerCase() !== String(item.contract).toLowerCase()) throw Error('Connect to this offer’s chain and escrow address first.');
      offer = await client.load(item.transaction); renderOffer(); message('Offer verified against on-chain storage.');
    })); li.append(button); $('history').append(li);
  }
}
$('connect').addEventListener('click', () => act(async () => {
  if (!window.ethereum) throw Error('Install an Ethereum browser wallet, then reload this page.');
  if (!artifact) throw Error('Contract data failed to load. Reload the page.');
  const current = ++epoch;
  const provider = new BrowserProvider(window.ethereum, undefined, { cacheTimeout: -1 });
  await provider.send('eth_requestAccounts', []);
  const candidate = await new SwapClient(provider, await provider.getSigner(), { chainId: $('chain').value.trim(), contract: $('contract').value.trim() }, artifact, message).ready();
  if (current !== epoch) throw Error('Wallet changed during connection. Try connecting again.');
  client = candidate; $('network-status').textContent = `Chain ${client.chainId} · verified`;
  $('account').textContent = `Connected: ${client.account}`; offer = null; $('offer').hidden = true; $('empty-offer').hidden = false;
  message('Wallet connected. Escrow runtime matches this application.');
}));
$('create').addEventListener('click', () => act(async () => {
  const current = epoch, active = client;
  const created = await active.create($('taker').value.trim(), basket('offered'), basket('requested'));
  if (current !== epoch) throw Error(`Wallet changed. Your offer creation transaction is ${created.transaction}. Reconnect to review.`);
  offer = created; renderOffer(); message(`Offer #${offer.id} is in escrow. Share the link with the receiver.`);
}));
$('load').addEventListener('click', () => act(async () => {
  const current = epoch, loaded = await client.load($('creation-tx').value.trim());
  if (current !== epoch) throw Error('Wallet changed. Reconnect to review.');
  offer = loaded; renderOffer(); message('Offer verified. Review every asset and address before proceeding.');
}));
async function settle(action) {
  const active = client, current = epoch;
  const receipt = await active[action](offer);
  if (current !== epoch) throw Error(`Wallet changed. Transaction confirmed: ${receipt.hash}. Reconnect to review.`);
  await active.refresh(offer); lastRefresh = Date.now();
  message(`${action === 'fill' ? 'Swap complete. Both sides received their assets.' : 'Offer cancelled. NFTs returned to the sender.'} Transaction: ${receipt.hash}`);
}
$('fill').addEventListener('click', () => act(() => settle('fill')));
$('cancel').addEventListener('click', () => act(() => settle('cancel')));
$('refresh').addEventListener('click', () => act(async () => { await client.refresh(offer); lastRefresh = Date.now(); message('On-chain status refreshed.'); }));
$('copy').addEventListener('click', () => act(async () => {
  try { await navigator.clipboard.writeText($('share').value); message('Offer link copied.'); }
  catch { $('share').focus(); $('share').select(); message('Select and copy the offer link from the field.'); }
}));
$('add-offered').addEventListener('click', () => addAsset('offered', '0', true));
$('add-requested').addEventListener('click', () => addAsset('requested', '1'));
for (const id of ['confirm-create', 'confirm-fill']) $(id).addEventListener('change', updateButtons);
$('create-fields').addEventListener('input', event => { if (event.target.id !== 'confirm-create') { $('confirm-create').checked = false; updateButtons(); } });
for (const id of ['chain', 'contract']) $(id).addEventListener('input', disconnect);
window.ethereum?.on?.('accountsChanged', disconnect); window.ethereum?.on?.('chainChanged', disconnect);
addAsset('offered', '0', true); addAsset('requested', '1'); renderHistory();
setInterval(updateButtons, 1000);
setInterval(() => { if (client && offer && !busy) act(async () => { await client.refresh(offer); lastRefresh = Date.now(); }); }, 15000);
try {
  const responses = await Promise.all([fetch('./config.json'), fetch('./contract.json')]);
  if (responses.some(r => !r.ok)) throw Error('Could not load deployment files.');
  const [config, contractArtifact] = await Promise.all(responses.map(r => r.json())); artifact = contractArtifact;
  $('chain').value = config.chainId; $('contract').value = config.contract; $('deployment-status').textContent = config.deploymentStatus;
  const shared = readShare(location.hash);
  if (shared) {
    $('creation-tx').value = shared.transaction;
    if (!config.contract) { $('chain').value = shared.chainId; $('contract').value = shared.contract; }
    message(`Shared offer: chain ${shared.chainId}, escrow ${shared.contract}. Verify these settings and connect to load it.`);
  }
} catch (error) { message(error.message, true); }
