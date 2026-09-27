# Implementation review and residual risks

This is an implementer's review, not an independent audit or a claim of unconditional safety. No separate reviewer has signed off on this source.

## Checked attack paths

| Concrete attempt | Enforced result / coverage |
| --- | --- |
| Outsider copies a receiver's calldata or attempts cancellation | Stored maker/taker checks reject; transaction sender is authenticated |
| Attacker creates an offer using a victim's existing NFT approval | NFT pull source is `msg.sender`; owner check rejects |
| Receiver adds, omits, reorders, or changes asset fields | Full ABI-encoded basket hash mismatch rejects |
| Receiver fills at exactly +1800 seconds, or later | Timestamp comparison rejects; sender can still reclaim |
| Receiver replays a successful/cancelled offer ID | Closed state rejects |
| Receiver tries to exploit a cancelled then recreated offer | New offer gets a new monotonically increasing ID |
| Token returns false, malformed data, deducts a fee, or adds a bonus | Safe return check and both-party balance deltas reject |
| Incoming consideration succeeds but a later NFT transfer fails | Entire payment, NFT movements, allowance changes and state revert |
| ERC-20 callback or recipient NFT callback reenters | Shared guard rejects; all entry points are covered by receiver callback tests |
| Receiver rejects NFT callback | Only its offer fails; maker refunds and other offers remain usable |
| Contract maker rejects NFT receiver hook on refund | Refund uses transferFrom to original maker without a hook |
| ERC-721 collection supplied as currency using shared transfer selectors | ERC-165 check rejects standard-advertising NFT collections in ERC-20 slots; regression test covers NFT #1 |
| Duplicate or oversized basket | Creation rejects before any custody transfer |
| Unsolicited safe NFT deposit / native ETH attached to fill | No receiver hook or payable entry point; transaction rejects |
| Administration used to inflate launch token or change implementation | No such functions; fixed supply and opcode checks exercised |

Stateful tests additionally reconcile each known NFT's owner with its offer state and all mock payment balances with the recorded successful fills, then reclaim every remaining open offer.

## Boundaries requiring review and user judgment

- Arbitrary token code can lie about ownership/balances, rebase, blocklist, pause, confiscate, upgrade, consume excessive gas, or change behavior later. ERC-165 and balance/owner postconditions do not prove honesty. A malicious asset can affect its own trade. Evaluate the actual collections/currencies, especially upgrade/admin authority, before trading.
- This is an offer with sender cancellation, not a guarantee that either party will perform. The taker does not lock consideration beforehand. Token approvals, balances, and time can change between wallet estimation and inclusion. A failed transaction consumes gas even though assets roll back.
- Consensus time/inclusion, censorship, chain reorgs, gas bidding and network/RPC failures are beyond the escrow. Thirty minutes is measured from the creation block timestamp, and fill must be included strictly before expiry. The design cannot promise that outsiders cannot cause network-level delay.
- Standard safe NFT receipt hooks are required during fill. A recipient that transfers the just-received NFT away inside its callback fails the ownership postcondition. Contract-wallet NFT receiver behavior needs live testing. Refunds intentionally skip the hook.
- Lost keys or unavailable makers cannot be recovered by an admin. Direct unsafe NFT/ERC-20 transfers and forced ETH are not attributed to an offer and have no rescue route. There is no keeper that returns assets automatically after 30 minutes.
- Browser code, wallet providers, the operating system, DNS/TLS, and selected RPC remain trusted for displaying/signing the intended transaction. Share inputs are data, never inserted as HTML; loaded terms are checked against storage. Runtime hash checks bind the app to these compiled contracts, but a compromised host could change both code and expected hash.
- Tests use representative local mocks, not every token implementation, production wallets, or adversarial validators. Independent review and public deployment smoke tests remain outstanding. No claim of a completed public launch is made.

Foundry's conservative lint warnings for external calls in bounded loops, event emission after external calls, and reentrancy near the guard reset are expected here. Public mutators set the shared guard before interactions, and any callback attempting another mutator reverts; reentrancy tests exercise those paths. No lint warning was treated as a substitute for inspecting the actual ordering.
