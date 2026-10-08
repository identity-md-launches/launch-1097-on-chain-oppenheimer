# Local security review

This is the implementation author's review, based on the supplied v4-security, Ethereum security and testing references. It is not an independent audit. Scope: the two production contracts, launch manifest, CREATE2 helper and settlement tests.

| Area | Finding and evidence |
| --- | --- |
| Authority | No owner, roles, setter, mint after construction, proxy or upgrade mechanism. Constructor fixes manager and launch token; IMD and DEAD are constants. Every implemented callback checks the manager. Unauthorized callback and unexpected unlock tests pass. |
| Pool binding | Immutable pool ID includes the sorted token pair, fee, spacing and hook. Initialization rejects foreign keys and dynamic fees. A predicted address without code cannot initialize. There is no pool-key substitution in batch calldata. |
| Permissions | Constructor validates exactly `0x20c4`. CREATE2 deployment and the offline miner agree. Only initialization, beforeSwap, afterSwap and afterSwap return-delta permissions are set. |
| NoOp exposure | No beforeSwap return-delta permission, no amount reservation, and no custom liquidity accounting. beforeSwap returns zero for both the delta and LP override. |
| Fee accounting | Tests compare final router deltas and actual token movements with the independent raw `PoolManager.Swap` event. Every charged fee equals floor(abs(unspecified raw delta)/100), on full and partial fills in both directions and both token orderings. |
| Callback transfers | Only PoolManager claim minting and slot reads occur in afterSwap. No external token transfer or buyback can fail inside the callback. The locally deployed manager has no native-currency funding requirement. |
| Claim settlement | Claim mint creates a hook debit offset by the returned fee delta. Sweep burns a claim for credit and takes exactly that amount. Batch burns only the IMD claims spent, settles any remaining direct input, and takes exactly the NUKE output to DEAD. The manager ends each unlock with zero debts. |
| Batch isolation | sweep and executeBatch reject calls while the manager is unlocked, including calls from a router unlock callback. A busy guard covers token transfers and restricts unlockCallback to an operation started by this hook. No external party can choose a batch's budget, limit, recipient or pool. |
| Partial fills | Budget is at most 25% of pending IMD; settlement uses actual swap deltas. Tight-limit tests hit the limit, retain the remainder, and successfully run another batch later. No minimum-output calculation encodes the LP fee. Empty liquidity completes normally. |
| Time reference | Hourly tick integrals use the previous tick for elapsed time. Multiple-observation fuzz tests independently integrate elapsed segments, including negative rounding and same-block trades. Long gaps roll over in constant work. Own batches manually observe their resulting tick because core skips self-callbacks. |
| Arithmetic | A raw delta is int128 and is widened before taking its absolute value. Multiplication by 100 fits uint256 and the fee fits int128. `beforeSwap` handles int256.min without negation overflow and rejects the documented unrepresentable request domain. An hourly integral is bounded by 887272 × 3600, well inside int64. Average tick remains within TickMath's domain. Sqrt scaling uses FullMath and legal-limit clamps. Timestamps fit uint64 on Ethereum's practical lifetime. |
| Fixed supply | NUKE mints exactly 1e27 to its deployer. Transfers are standard OpenZeppelin ERC-20 transfers. Factory allocation, allowance failure, conservation and absence of mint/admin entry points are covered. Sending tokens to DEAD does not alter totalSupply. |
| Deployment bytes | With pinned settings, NUKE runtime is 1,503 bytes and creation code is 2,474 bytes. NUKEHook runtime is 10,206 bytes and creation code is 11,314 bytes (11,378 including its two arguments). Tests assert EIP-170/EIP-3860 limits and scan runtime opcodes, skipping PUSH data, for SELFDESTRUCT, DELEGATECALL and CALLCODE. |
| Conservation | Stateful fuzzing interleaves all swap modes, time advances, batches and sweeps. Raw swap-event fees equal pending plus spent/burned balances over 128 sequences × 64 calls with fail-on-revert enabled. The manager remains locked with no unsettled deltas. |
| Live integration | The mainnet fork at block 26,150,493 uses real IMD and PoolManager code. Both integration tests passed, covering the four swap modes and partial fills plus fee sweep and batch burn. |

## Remaining release responsibilities

- Independent adversarial review of the immutable launch and its integration with the actual factory, including the factory's allocation and LP position setup. This project does not implement the factory or Merkle distributor.
- Rehearse the final factory transaction at its actual opening price and liquidity, and verify the deployed sources with the exact compilation settings and constructor arguments. The delivered fork harness initializes its own test pool at 1:1.
- Operate and monitor permissionless maintenance calls; no built-in reward guarantees somebody will pay gas to run them.

The reference is a pool-derived oracle, not an external fair-price feed. A party sustaining price distortion over an observation window can affect it, and low liquidity can increase that risk. Hourly completed-window lag can defer a buyback; the contract preserves its accrued funds and leaves ordinary swaps available. Pending claims share PoolManager's custody and settlement assumptions. Third-party token behavior and protocol availability remain external dependencies.

Slither, Mythril, formal verification and an independent audit were not run in this assignment. The test suite and this review do not claim those assurances.
