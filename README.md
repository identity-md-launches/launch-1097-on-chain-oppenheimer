# On-Chain Oppenheimer (NUKE)

A complete Foundry launch project for Ethereum mainnet. The only production deployments are `src/NUKE.sol:NUKE` and `src/NUKEHook.sol:NUKEHook`. `launch.json` names those contracts directly. There is no owner, setter, proxy, upgrade mechanism, external oracle, or privileged keeper.

## Build and check

```sh
forge build
forge test
forge fmt --check
```

Solidity **0.8.26**, Cancun, optimizer **200 runs**, via IR, and `bytecode_hash = "none"` are pinned in `foundry.toml`. All imported sources and licenses are ordinary files in `lib/`; there are no submodules, package installation steps, FFI or filesystem permissions. Foundry and the pinned compiler must be installed by the execution environment. `dependencies.json` records the upstream commits; `remappings.txt` resolves imports without network access.

Default tests run against the actual vendored v4 `PoolManager`, deployed locally. They CREATE2-mine the hook and exercise both currency orderings, four swap modes, price-limited partial fills, fee rounding, extreme requests, failure paths, buyback limits, oracle timing, burn accounting, runtime opcode restrictions, and randomized sequences of swaps/batches/sweeps. Mainnet-only tests explicitly skip when no fork is selected; tests never read or set environment variables.

```sh
forge test --match-contract MainnetForkTest \
  --fork-url https://ethereum-rpc.publicnode.com --fork-block-number 26150958
```

This revision passed both fork integration tests at **26,150,958**, against the supplied live PoolManager and IMD addresses, including exact-input/output buys/sells and partial fills, fee redemption, batch buybacks and burns. Test-only balance funding uses Foundry `deal`; the live token/manager code is preserved. The public RPC no longer served historical state for the previous revision's block 26,150,493; the revision was rerun at the newer pinned block above. Substitute another archive RPC if needed. The default offline suite does not need that RPC.

## Fixed deployment terms

| Parameter | Value |
| --- | --- |
| Chain | Ethereum mainnet, chain ID 1 |
| PoolManager constructor argument | `0x000000000004444c5dc75cB358380D2e3dE08A90` |
| Launch token constructor argument | Factory-deployed NUKE, manifest `$token` |
| Paired currency | IMD, `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` |
| Token supply | 1,000,000,000 NUKE, 18 decimals, `1e27` units |
| Static LP fee / spacing | 12500 (1.25%) / 60 |
| Hook fee | 100 bps, immutable |
| Burn destination | `0x000000000000000000000000000000000000dEaD` |
| Hook address permission mask | `address & 0x3fff == 0x20c4` (8388) |

NUKE is OpenZeppelin's standard ERC-20 with a single constructor mint of **the entire supply to its deployer** and no additional logic. The launch factory supplies 90% to the pool and routes the swarm's 10% through its Merkle distributor, with any remainder to its `remainderTo`. These allocations are not performed by the token or hook. Sending NUKE to DEAD permanently removes it from accessible balances but does **not** decrement ERC-20 `totalSupply`.

`NUKEHook(IPoolManager manager, address launchToken)` fixes all addresses at construction. The manager and token must have code. IMD and DEAD are fixed constants. The hook accepts only the canonical sorted NUKE/IMD key with fee 12500, spacing 60 and itself as the hook. All enabled callbacks and `unlockCallback` verify their caller is the manager. The initialization callback prevents pool initialization at a predicted hook address without deployed code. The launch factory must deploy the token, deploy the hook and initialize/seed the pool atomically. There is no separate factory allowlist or post-deployment setup.

The manifest's `initialPrice = 79228162514264337593543950336` is provenance, not an enforced opening price. The factory derives the actual price from launch economics; the hook initializes its reference using that actual price.

## Fees and accounting

Enabled permissions: **beforeInitialize, beforeSwap, afterSwap, afterSwapReturnDelta**. All other flags, including beforeSwapReturnDelta, are false. `beforeSwap` returns zero deltas and zero LP override. It only rejects requests whose absolute specified amount plus its 1% fee allowance cannot fit in `int256`, using `UnrepresentableFee`.

`afterSwap` calculates `floor(abs(actual unspecified BalanceDelta) / 100)` and returns a positive unspecified delta. There is no fee reservation or refund to reconcile. The specified leg remains untouched, so a partial fill pays only on what actually filled. The pool's LP fee remains 1.25%.

| Swap mode | Unspecified currency charged | Effect |
| --- | --- | --- |
| Exact-input buy NUKE | NUKE output | Output reduced by 1% of gross output |
| Exact-input sell NUKE | IMD output | Output reduced by 1% of gross output |
| Exact-output buy NUKE | IMD input | Input increased by 1% of actual input |
| Exact-output sell NUKE | NUKE input | Input increased by 1% of actual input |

Fees are minted as **ERC-6909 claims owned by the hook** inside the PoolManager. They are backed when the enclosing swap settles. No ERC-20 transfer, balance query to IMD, or buyback occurs in a swap callback. This permits collection even before a router settles its input. `pending()` includes IMD claims plus IMD held directly by the hook; `pendingBurn()` similarly includes NUKE claims and direct NUKE donations.

`sweep()` is permissionless. In a separate manager unlock it burns all NUKE claims and transfers the redeemed NUKE directly to DEAD, then sends any directly held NUKE there. It never spends IMD. Repeated empty sweeps are harmless.

## Buybacks and reference price

`executeBatch()` is permissionless and must run while the PoolManager is locked, outside any swap/router unlock. Its first batch requires a full **3600 seconds after initialization**; subsequent batches require 3600 seconds since the last batch that filled at least 1% of its budget. `lastBatch()` starts at initialization time to enforce warmup.

Budget is `floor(pending() / 4)` (at most 25%, capped further at `int128.max` for v4 delta representation). The hook unlocks the manager, swaps exact-input IMD for NUKE, and settles **only the actual input spent**. It burns IMD claims first and uses `sync → transfer → settle` only for any remaining input funded by direct donations. All acquired NUKE goes directly to DEAD. PoolManager omits callbacks for swaps initiated by the hook itself, so batch swaps incur the LP fee and no hook fee. The hook explicitly refreshes its observation after its own swap.

The reference is the **geometric mean price from the time-weighted observed tick in the most recently completed, launch-aligned one-hour window**. This is an exact hourly window, not a spot observation or a sliding-window approximation. Before that first window completes, `referencePrice()` reports the initial tick's sqrt price, but batches are disabled. Elapsed time is credited to the previous observation. Negative mean ticks round down. Window rollover and arbitrarily long idle periods take constant work. The view projects elapsed time even without a new transaction.

**What an observation is.** After every swap, including its own batches, the hook records the price at which the pool could actually sell a standard depth of NUKE, not the raw `slot0` tick. `observationDepth()` is 0.25% of the NUKE the PoolManager holds outside the hook's own unburned fee claims (about 2.25M NUKE at launch, shrinking as the pool's inventory is bought). `askPrice()` walks initialized ticks from the spot in the buying direction exactly as the swap loop would, for at most 16 steps, and returns the sqrt price at which that depth would have been bought. A spot in an empty region, or inside a dust position with nothing behind it, cannot sell that depth nearby and has **no observable price**: the hook carries its previous observation forward. A full-range launch position sells about 1.5% of its inventory within 3% of price, so it sells the observation depth within about 50 ticks (0.5%) of spot; a narrower seed position sells it closer. In normal operation the observed tick is therefore spot plus that small depth offset, and the batch limit of 3% beyond the reference and the executable spot can reach up to about 3.5% beyond the raw `slot0` price. `observedTick()` exposes the tick currently accruing time. Inside `afterSwap` the swapper has not settled yet, so the depth is computed from the pre-swap balance; a resting `askPrice()` call after the swap can differ by a tick or a few for very large swaps.

**Band.** Each observation may sit at most `BAND_TICKS = 2000` (about 18% in price) on the cheap side of the latest completed hour's mean; cheaper observations are clamped to that floor. A single block at a manipulated low tick can therefore shift the next hour's mean by at most 2000 × 12 / 3600 ≈ 7 ticks, and reaching the 296-tick shift that would block a batch needs the manipulated state to persist for 15% of the hour. A genuine fall of more than 18% per hour is tracked at 2000 ticks per hour; the spot cap below keeps batches executable in the meantime. Rises are not banded.

`referencePrice()` returns **sqrt(token1/token0) in Q64.96**, using sorted pool currencies. Tick quantization is inherited from v4. The batch limit permits a maximum **3% adverse move in IMD per NUKE** from both that reference and the executable spot, which is `askPrice()` when it is found:

- NUKE is currency0: upper sqrt limit = min(reference, ask) × sqrt(1.03), rounded conservatively.
- NUKE is currency1: lower sqrt limit = max(reference, ask) / sqrt(1.03), rounded conservatively.

The executable spot can only tighten the reference bound. When no ask is found, the reference alone sets the limit: an empty-region or dust tick is freely movable and cannot be used as a market price. This lets a batch cross an empty region or a dust position back into real liquidity in a single call.

Both limits are clamped inside v4's legal sqrt-price range. `batchPriceLimit()` exposes the computed value. The **price limit is the sole slippage guard**: there is no quoted minimum output, budget-based output floor, or assumption about how much output remains after LP/protocol fees. If the price limit is reached, the trade accepts a partial fill; all unused IMD remains in `pending()`. If the budget rounds to zero or spot is already beyond the limit, the call returns `(0,0)` and does not consume the cooldown. If a swap buys zero NUKE (including an empty-liquidity swap or rounding-only input charge), its entire manager unlock is rolled back and the call returns `(0,0)` without consuming the cooldown or spending funds. Other manager or settlement failures still revert. A fill below **1% of the budget** (`MIN_FILL_DIVISOR`) keeps what it bought but does **not** consume the interval: a griefer parking spot a few sqrt-price units inside the limit can make a call buy a few wei, but cannot spend the hourly slot on it. Fills at or above 1% of the budget commit `lastBatch`. Repeated sub-floor fills are bounded by the same price limit: once spot reaches it the next call returns `(0,0)` until someone sells NUKE back below it.

## Deployment and operation

1. Build using the pinned settings. The factory deploys NUKE first and must hold `1e27` units before distributing.
2. Construct NUKEHook init code with ABI-encoded `($poolManager, $token)`. Mine a salt **for the factory actually issuing CREATE2**, with low 14 bits `0x20c4`. Do not insert a wrapper.
3. Deploy that init code at the mined address. The constructor validates its address permissions. Initialize the exact key and seed liquidity in the same factory transaction.
4. Verify both deployed sources immediately on Sourcify/Etherscan using the exact compiler settings, vendored source tree, constructor arguments and standard JSON build input. Save the salt, init-code hash, opening price and pool ID. A change to settings, factory, token or constructor args requires remining.
5. An operator (or any participant) calls `sweep()` when NUKE fees warrant gas and `executeBatch()` when its interval and price limit allow. There is no keeper payment or automatic transaction scheduling. Monitor `FeeAccrued`, `Swept`, `BatchExecuted`, pending balances and the relationship between `referencePrice()`, `askPrice()`, `observedTick()` and `batchPriceLimit()`. A `BatchExecuted` whose `spent` is below 1% of `budget` did not advance `lastBatch()`.

The offline helper `script/MineHook.s.sol:MineHook` searches a caller-specified salt range and returns the predicted address, salt and init-code hash. It never broadcasts:

```sh
forge script script/MineHook.s.sol:MineHook \
  --sig 'run(address,address,address,uint256,uint256)' \
  "$POOL_MANAGER" "$DEPLOYED_NUKE" "$ACTUAL_CREATE2_FACTORY" 0 300000
```

Those shell variables are values provided by the launch deployment, not environment reads inside the script. The factory must check the predicted address is unused. No unknown recipient, owner or oracle value is required by these contracts.

## Assumptions and review limits

IMD is the supplied 18-decimal mainnet token; this is not a generic fee-on-transfer/rebasing-token adapter. The live fork exercises its actual transfers. Standard user swaps remain subject to v4's own validity, liquidity and settlement requirements; the hook adds no price, sender or cooldown restriction to them. Accrual cannot be blocked by an ERC-20 transfer from the hook during callbacks because none occurs.

The hourly reference resists instantaneous manipulation: a same-block price move has no elapsed weight. It can still be influenced by holding a manipulated pool price over time. Its completed-window definition also intentionally lags changing markets. The executable-spot cap prevents a stale high reference from widening the permitted adverse move beyond 3% of the price at which the observation depth is purchasable. The 3% bound and 25% budget limit exposure; they do not eliminate MEV or provide an external fair-price guarantee. A batch outside the bound can wait for a later reference window without blocking user swaps.

**Cost of pushing the reference down.** Because an observation must be backed by 0.25% of the pool's NUKE for sale within reach of the spot, a free tick push (an empty region, or a 1 wei dust position at the extreme ticks) is ignored. To record a cheaper tick an attacker has to offer that depth of NUKE at the cheaper price, which the batch itself (and any arbitrageur) can buy; selling it into their own position costs the 1% hook fee on the IMD leg every time, and that fee funds the buyback. The band then requires the cheaper state to persist for at least 15% of an hour, and any real trade through the pool restores the real observation. Residual: in a market with no other trades, one such wash-park per hour, withdrawn before the next batch could buy it, keeps the carried observation at its price for the hour at the cost of that fee. The observation depth is relative to the NUKE the PoolManager holds; NUKE deposited into other v4 pools raises it. The launch position sells about 1.5% of its inventory within 3% of price, so other v4 pools would have to hold roughly five times this pool's NUKE before launch-pool observations stop; if that ever happened the oracle would carry its last observation until the ratio recovers, and batches would stall if the price rose meanwhile.

Revision regression tests cover stale-reference round trips, zero-liquidity observations, direct buybacks across empty regions and dust positions, the reported dust-liquidity tick push in both orderings, a backed discounted ask that is observed and bought, the band clamp, zero-output batch rollback, and fills just above and below the 1% interval floor.

The local security review and its evidence are in `docs/SECURITY_REVIEW.md`. No mainnet deployment or funded-wallet action was performed. An independent adversarial review remains a release responsibility; Slither, Mythril and formal verification were not run.
