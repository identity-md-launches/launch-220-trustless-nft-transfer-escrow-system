# Pairwise

An immutable, private-counterparty NFT escrow and a self-contained wallet frontend. A sender escrows ERC-721 NFTs and names one receiver plus an exact basket of ERC-20 tokens and/or ERC-721 NFTs. Only that receiver can submit the matching transaction. Settlement moves both sides atomically; failed settlement moves nothing.

**Deployment status:** implemented and locally tested; no public contracts or hosted URL have been deployed by this assignment. `frontend/config.json` is deliberately unconfigured. The intended default network is Sepolia (11155111), subject to the launch operator's confirmation. Public deployment needs a factory deployment and a static hosting destination. No key or funded wallet is used by the project scripts.

## Run and verify offline

Requirements: Foundry (tested with 1.8.3), Node.js (tested with 24.21.0), and Python 3 for the optional preview. Solidity 0.8.26 for Linux x86-64, forge-std 1.9.7, and ethers 6.13.5 are vendored as ordinary files. There are no submodules, npm dependencies, CDN requests, FFI, or Solidity test filesystem permissions.

```sh
# In this restricted workspace, use the included normal SVM cache.
export XDG_DATA_HOME="$PWD/toolchain"
forge build --offline
forge test --offline
forge fmt --check
node scripts/export-frontend.mjs
node --test frontend/test/*.test.mjs
python3 scripts/serve.py
```

Open <http://127.0.0.1:8080>. The frontend is a static site requiring an injected Ethereum wallet; it is not a public deployment. `bash scripts/check.sh` runs all checks in sequence. The client integration test starts an ephemeral, silent Anvil process on loopback, uses unlocked **local test** accounts, and shuts it down. It never uses an external RPC or a wallet key.

On systems with `~/.svm`, Foundry prefers that cache; provision Solidity 0.8.26 there before going offline. The included binary is an unmodified official compiler, not a compiler wrapper. On other operating systems/architectures, provision the native 0.8.26 compiler as part of the toolchain. The Solidity configuration always selects the version, not an executable path.

## Using an offer

1. Connect a wallet to the configured chain and independently verified `NFTSwap` address. The frontend checks the deployed runtime hash against its locally built artifact.
2. Enter the receiver's full address, 1–16 NFTs to send, and 1–16 requested assets. ERC-721 entries use collection address and token ID (including ID zero). ERC-20 entries use token address and **integer minor units**, with ID zero. For example, one 18-decimal token is `1000000000000000000` units. Verify decimals independently; the UI does not trust token metadata or floating-point conversions.
3. Review the terms and approve the offered NFTs individually. Sign `createOffer`. NFTs move into escrow; the 30-minute deadline starts at **block inclusion**, not when a wallet prompt opens. Save the creation transaction hash or share link.
4. The named receiver loads the creation transaction. The app extracts its offer event, checks its terms against storage, and shows both baskets, parties, and expiry. After explicit review, it requests necessary exact approvals and signs `fillOffer` with the committed arrays. Both sides settle in the same transaction.
5. The sender can cancel while open, including after expiry, to return all escrowed NFTs. There is no automatic timed transaction or keeper. Expiry makes filling impossible even if storage still says `Open`; reclaim requires a sender transaction and gas.

The frontend resets a nonzero insufficient ERC-20 allowance to zero before approving the exact payment, never requests an infinite approval, and uses per-ID NFT approvals. Existing sufficient approvals are reused. Approvals are independent transactions: if creation/settlement fails or expires, revoke unused approvals with your wallet or the token's own interface. The app's status poll and countdown are advisory; on-chain time decides validity. Keep gas available for approvals, settlement, or reclaim.

## Contracts and lifecycle

- `src/NFTSwap.sol:NFTSwap`: no constructor arguments, owner, fee, upgrade path, pause, arbitrary-call facility, or rescue authority. Offer IDs start at 1 and never repeat. Each offer binds sender, receiver, absolute expiry, and `keccak256(abi.encode(offered, requested))`.
- `src/Token.sol:Token`: separate launch ERC-20, `Pairwise` / `PAIR`, 18 decimals, exactly 1,000,000,000 tokens (`10^27` units), all minted to its constructor caller. No subsequent mint or admin functions. The escrow does not require this token and cannot move the factory's launch supply.
- `Asset = (uint8 kind, address token, uint256 id, uint256 amount)`. Kind 0 means ERC-721 with amount 1; kind 1 means ERC-20 with ID 0 and positive amount. Offered assets must be ERC-721. Requested baskets can mix kinds. Duplicates are rejected, including an NFT on both sides. Repeated ERC-20 amounts must be combined.
- The matching transaction is `fillOffer(id, offered, requested)`. Array length, order, type, contract, ID, and amount must match exactly. Adding anything, omitting anything, changing fields, attaching native ETH, or using a different caller fails.
- `Open → Filled` or `Open → Cancelled`. Filling requires `block.timestamp < expiresAt`. At exactly creation time + 1800 seconds the offer is invalid. Closed IDs can never be reused or filled again.
- `cancelOffer(id, offered, requested)` always refunds to the original sender. Sender cancellation and receiver settlement compete by block ordering; whichever succeeds first closes the offer. The sender has an explicit right to withdraw before acceptance.
- Wallet transactions provide authentication, chain binding, and account nonces. There is no separate EIP-712 signature, relay, server listener, matcher, or off-chain signature replay surface. The contract responds when the matching transaction executes.

## Asset and security assumptions

Supported assets are conventional, honest [ERC-721](https://eips.ethereum.org/EIPS/eip-721) and [ERC-20](https://eips.ethereum.org/EIPS/eip-20) contracts. ERC-1155, native ETH, fees on transfer, rebasing, and callback-dependent accounting are outside this version's support. Wrapped ETH works as an ordinary ERC-20. Use independently verified token addresses; these standards cannot prove economic value or prevent an issuer from lying, confiscating, upgrading, or pausing a token.

ERC-20 settlement accepts true or empty return data and verifies both the payer's exact decrease and recipient's exact increase. False, malformed, fee, and bonus transfers revert. ERC-721 collections advertising their standard are rejected in ERC-20 slots to avoid shared-selector ambiguity. This detects incompatible accounting in a transfer; it is not proof that a malicious token reports honest balances. ERC-721 ownership is checked before and after each movement. Fill recipients that are contracts must accept safe NFT transfers and retain the NFT through the callback. Incoming custody and sender refunds use `transferFrom` so sender recovery does not depend on a receiver hook.

All state-changing entry points share a reentrancy lock, close the offer before settlement/refund interactions, and revert atomically on any failure. A failing offer does not block an unrelated offer. Only maker/taker authorization can move an offer's assets; there are no caller-supplied settlement destinations. There is no `tx.origin` authorization, proxy, delegatecall, selfdestruct, or mutable protocol administrator.

Do not directly send assets to the escrow. Unsolicited safe NFT transfers and ordinary ETH sends revert. Plain NFT `transferFrom`, ERC-20 transfers, and forced ETH can still strand assets: there is deliberately no administrator who can sweep them. The app only accepts transfers made by its own offer flow.

No contract can guarantee that a validator includes a transaction promptly, prevent network censorship/congestion/reorgs, or stop a token issuer or either participant from refusing to cooperate. The taker may withhold payment; the maker can cancel; an issuer may block NFT recovery. An expired offer stays unfillable regardless of delay. Participants must allow confirmation time and verify the chain's finality. Frontend and RPC integrity remain operational trust assumptions even though on-chain terms constrain settlement.

## Validation and release

Tests cover NFT/currency/mixed baskets, ID zero, a maximum-sized basket, exact commitment mutations, unauthorized calls, expiry boundaries, cancellations/replay, insufficient approval, failed and inexact tokens, rejected NFT callbacks, multiple kinds of reentrancy, full settlement rollback, contract-wallet refunds, launch supply, and forbidden runtime opcodes. Fuzz tests exercise amounts/time and token conservation. Stateful invariants exercise interleaved creation, fill, cancellation, third-party attempts, and time advances, checking escrow custody, payment conservation, and eventual maker refunds.

Frontend tests exercise integer/address validation, share links, deadline/role checks, runtime/chain verification, exact approvals, receipt-based recovery, successful settlement, tampered offers, expiry, and cancellation against Anvil. They exercise the actual browser client module, not a mocked contract. Visual rendering and browser-wallet combinations still need operator acceptance testing.

Read [deployment and operations](docs/DEPLOYMENT.md), [security review notes](docs/SECURITY.md), and [dependency provenance](docs/DEPENDENCIES.md). Tests and this implementation review are not an independent security audit. An independent contributor should adversarially review custody behavior before a release holding real assets. The separate launch manifest/review stages must verify the actual deployed bytecode and published addresses.
