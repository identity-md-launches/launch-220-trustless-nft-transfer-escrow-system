# Deployment and operations

## Parameters for the launch manifest owner

This task supplies source and tests; the separate manifest owner writes `launch.json` from the accepted artifacts. No deployment or signed broadcast script is included.

| Artifact | Identifier | Constructor arguments | Purpose |
| --- | --- | --- | --- |
| `src/Token.sol:Token` | `Token` | none | Fixed launch ERC-20 |
| `src/NFTSwap.sol:NFTSwap` | `NFTSwap` | none | Application escrow |

Application contract order: `[NFTSwap]` (no dependencies or token references). Both constructors are nonpayable and fully configure the contracts; there are no initialization calls. Neither constructor assigns administrative rights to `msg.sender`. The token deliberately mints its entire supply to the factory caller, as required for launch distribution. Do not deploy mocks in `test/`.

Compiler: official 0.8.26, optimizer enabled at 200 runs, Cancun EVM, no bytecode metadata hash and no CBOR footer. Confirm the selected chain supports the Cancun instruction set. Runtime hashes depend on compiler settings: regenerate frontend contract data after any accepted source/configuration change. Do not silently substitute different bytecode for an existing deployment.

Proposed target: Sepolia, chain ID 11155111. The launch operator must confirm the chain, ProjectFactory address, approved launch policy, token allocation and liquidity parameters, factory salts, and resulting token/application addresses. This application adds no policy parameters or privileged beneficiaries. There is no owner/fee/pause configuration. Do not guess protocol factory addresses, fund wallets, or copy private keys into source or frontend configuration.

## Publish the static frontend

1. Complete source review, run `bash scripts/check.sh`, and record the accepted source revision and artifact hashes. Independently review custody, exact token transfers, deadlines, and the final launch manifest.
2. The authorized launch process deploys the fixed-supply token and NFTSwap via ProjectFactory. Record transaction receipts, chain ID, factory, contract addresses, runtime bytecodes/hashes, and launch policy. Verify token supply and the factory's constructor-time balance.
3. Run `node scripts/export-frontend.mjs`. Compare `frontend/contract.json`'s runtime hash to `keccak256(eth_getCode(NFTSwap))` on the intended chain using an independent RPC. There are no linked libraries or immutables to patch.
4. Set the reviewed public deployment with `node scripts/configure-frontend.mjs 11155111 0xYourActualNFTSwapAddress`. The script only writes configuration; it does not deploy anything. Publish the public deployment record alongside the site, including the token address. Never publish a placeholder address as a working deployment.
5. Upload **only the entire `frontend/` directory** to the selected HTTPS static host; no package installation or build service is needed. Its `vendor/`, `contract.json`, `config.json`, `.mjs` files, HTML and CSS must all be present. Serve `.mjs` as JavaScript and `.json` as JSON. Do not rewrite missing module paths to `index.html`.
6. Keep the page CSP. Set HTTP headers `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`, and `Content-Security-Policy: frame-ancestors 'none'` in the host's settings (frame-ancestors must be a response header). Do not cache `index.html`, `config.json`, or `contract.json` across a deployment without revalidation. No analytics, backend, public RPC key, or third-party CDN is required: the connected wallet supplies RPC access.
7. From two test wallets, verify create → share → load → fill for NFT/ERC-20 and NFT/NFT. Also test expiry/reclaim, wallet rejection, account/network changes, and mobile layouts. Inspect every wallet's approval target and payment amount. Publish the HTTPS URL and verified address record only after this passes.

**Current release:** static build ready; public chain deployment and hosting pending. `python3 scripts/serve.py` is a loopback preview, not a production host. Hosting account, domain, real contract address, production wallet testing, and public finality policy remain operator decisions.

## Operational responsibilities

- **Maker:** verify token contracts and receiver address; retain the creation transaction hash; keep gas to reclaim; reclaim expired/cancelled intentions via `cancelOffer`. NFTs do not automatically return at expiry. Cancellation itself must be mined before a competing valid fill to win.
- **Taker:** inspect exact terms and expiry; approve only necessary assets; submit sufficiently early; wait for confirmation and verify ownership/balances. Reject unknown token contracts; being ERC-20 compatible does not make a token valuable.
- **Both participants:** protect wallet access, check full chain/contract addresses, trust appropriate token issuers, and manage/revoke any unused approvals. A lost wallet key has no escrow administrator recovery path.
- **Host/operator:** keep deployment records and static code authentic, manage TLS/domain availability, provide chain finality guidance and incident communications, preserve event access through usable RPCs, and arrange independent review. Operators have no on-chain custody powers.
- **RPC/wallet provider:** serve accurate code, receipts, state, time, estimates, and inclusion status. A full contract/runtime verification does not protect against a completely dishonest wallet/RPC or a modified frontend.

If the website disappears, anyone can reconstruct the exact offered/requested arrays from the `OfferCreated` event in the creation receipt. Use the public ABI in `frontend/contract.json` to invoke `offers`, `fillOffer`, or `cancelOffer` through a trusted wallet/contract interface. Neither party needs the host, an indexer, or a permissioned backend. Match array order exactly. Expired status is computed from `expiresAt`; do not assume an `Open` enum means fillable.

There is no upgrade/pause/rescue mechanism. A discovered application defect requires stopping frontend creation, public communication, maker cancellations where possible, and a new reviewed deployment. Never advertise that an operator can freeze or recover users' funds. A token contract defect or freeze may prevent escrow recovery and needs resolution by that issuer.

## Gas choices

Offers store three slots (packed maker/time/status, taker, terms commitment) instead of storing both baskets. Complete terms are emitted once and supplied by the caller on fill/refund. A single receiver transaction settles all assets, with no ERC-20 custody or follow-up payout transaction. Basket sizes cap at 16 on each side; duplicate checks are bounded quadratic loops. The contract deliberately retains ownership, exact-balance, and reentrancy checks despite their gas cost.

Gas depends on token implementations and basket size; fees also depend on the network's gas price. Run `forge test --offline --gas-report` for measured calls against the supplied test tokens. Never interpret test gas as a fee quote for an arbitrary collection. The wallet estimates each real approval and escrow transaction immediately before signing.
