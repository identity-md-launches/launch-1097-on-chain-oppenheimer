# Additional adversarial coverage

These tests extend the existing NUKE launch suite without changing production contracts or configuration.

- `SettlementEdges.t.sol`: reverted input settlement, atomic rollback and retry of sweep/batch transfers, ERC-6909-funded swaps in all four modes with full and partial fills, budget dust, additional protocol fees, and the exact int256 request boundary. Both currency orderings run the same assertions. Fuzz properties use 1,000 runs each.
- `FreshPoolClaimsTest` and its reverse-order variant seed a new real PoolManager with only NUKE. They observe zero IMD reserves after the first buy's callback, before the router pays its input, and verify that the resulting claims can be swept or used for a buyback.
- `StatefulAccounting.t.sol`: 256 sequences of 96 calls per ordering, mixing price-limited trades, unlimited market orders of 10k–300k tokens, token/claim donations, elapsed time, batches, sweeps, forged callbacks, complete liquidity removal/restoration, and extra positions opened and closed at ranges next to spot, across a wide band, and straddling the first two tick-bitmap word boundaries. Unexpected reverts fail the run. Accounting comes from raw PoolManager swap events and actual donations. Invariants reconcile physical token balances and claims, enforce fixed supply and zero unsettled debts, and compare the oracle against an independent model (below). Deterministic regressions cover each case in both currency orderings: carried observations across empty-region movement, zero-budget attempts that observe nothing, funded zero-output batches that keep their pre-swap observation, the band clamp on a large sale and its absence on a large buy, shaped liquidity, and liquidity recovery retried within the same timestamp. Fills below 1% of the budget must keep what they bought without advancing `lastBatch()`; fills at or above it must commit it.
- `MainnetFork.t.sol`: adds a backed IMD claim donation, price-limited partial buyback, preservation of unused claims, subsequent batch, and donation sweep against the deployed manager and token.

## Oracle model in the stateful campaign

The hook now records, after every swap and funded batch, the price at which `observationDepth()` NUKE is purchasable, found by walking initialized ticks, carried when nothing of that size is for sale nearby, and clamped to at most `BAND_TICKS` below the last completed hour's mean. The handler never reads the hook's walk to decide what it should have observed:

- `ClaimActor.probeAsk` runs a real exact-output buy of the depth through the PoolManager and reverts its own unlock, returning where the swap engine landed and whether the whole depth filled. For swaps, the depth is the one the hook saw inside `afterSwap`: the router records the manager's NUKE balance and the hook's NUKE claims before the swapper settles, and the handler subtracts the fee claim minted after the observation.
- The expected observation is the engine's landing tick, or the previous observation when the depth did not fill, clamped against the model's own mean of the last completed hour computed from timestamped history. The hook's `observedTick()` must match after every swap and funded batch (a funded batch observes the resting state before its swap and again after a fill; the model records both), and must not move after donations, sweeps, liquidity changes, elapsed time, refused batches or forged callbacks.
- At every step the hook's `askPrice()` view is compared with the engine: same verdict on whether the depth is for sale and, when it is, the same price.
- One tick of tolerance applies only when the engine landed exactly on a tick's sqrt price: when a segment's floor-rounded amount equals the remaining depth exactly, core crosses to the tick while the hook prices the fill from the amount. Both read the same state; with liquidity of at least 1e18 they are at most one tick apart, which is why the campaign's extra positions start there (a 14049-liquidity position produced a 0.3-tick gap under seed 0x2a before the floor). The `pre-settlement` depth makes the hook's post-swap observation of a large buy sit a few ticks beyond a resting `askPrice()`; the model reproduces that rather than tolerating it.
- Spot is kept within ±100000 ticks (market orders stop 50000 ticks out) so every position stays within the hook's 16-step walk and the engine comparison remains exact; beyond 16 initialized ticks or empty words the hook deliberately reports no price and carries the previous observation.

Local tests use the vendored PoolManager implementation, a standard ERC-20 at IMD's specified address, genuine constructor-deployed NUKE tokens, and CREATE2-mined hooks. Only the transfer-failure tests mock external calls, to verify rollback; ordinary swap and batch tests do not mock the manager. No environment variables are changed.

Offline verification (artifacts stay in disposable scratch space):

```sh
forge build --offline --out test/scratch/out --cache-path test/scratch/cache
forge test --offline --out test/scratch/out --cache-path test/scratch/cache
```

Fork verification requires network access and is explicitly skipped when no fork is selected:

```sh
forge test --match-contract MainnetForkTest \
  --fork-url https://ethereum-rpc.publicnode.com --fork-block-number 26151012 \
  --no-storage-caching --out test/scratch/out --cache-path test/scratch/cache
```

The factory's Merkle distribution and deployment orchestration are outside this tests-only assignment. Claim donations are always funded through actual transfers and settlement; none of these tests substitutes a guessed deployment recipient or writes fabricated balances into the hook.

Revision verification (2026-10-09): `forge build` succeeded; the offline suite passed 136 tests with one explicit fork-setup skip. Both stateful campaigns completed 256 sequences of 96 calls with zero reverts under the default seed and seeds 0x1, 0x2a, 0xdeadbeef, 0x7777 and 0xabc123. The mainnet fork tests were not rerun in this revision (no network); the previous run passed at block 26,151,012. Measured with the vendored manager: `askPrice()` costs about 29k gas in a single-position pool and about 99k when it walks 16 dust ticks and gives up; a router swap in the single-position pool costs about 187k gas in total.
