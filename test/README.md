# Additional adversarial coverage

These tests extend the existing NUKE launch suite without changing production contracts or configuration.

- `SettlementEdges.t.sol`: reverted input settlement, atomic rollback and retry of sweep/batch transfers, ERC-6909-funded swaps in all four modes with full and partial fills, budget dust, additional protocol fees, and the exact int256 request boundary. Both currency orderings run the same assertions. Fuzz properties use 1,000 runs each.
- `FreshPoolClaimsTest` and its reverse-order variant seed a new real PoolManager with only NUKE. They observe zero IMD reserves after the first buy's callback, before the router pays its input, and verify that the resulting claims can be swept or used for a buyback.
- `StatefulAccounting.t.sol`: 256 sequences of 96 calls per ordering, mixing price-limited trades, token/claim donations, elapsed time, batches, sweeps, forged callbacks, and complete liquidity removal/restoration. Unexpected reverts fail the run. Accounting comes from raw PoolManager swap events and actual donations. Invariants reconcile physical token balances and claims, enforce fixed supply and zero unsettled debts, and compare the oracle against an independent integration of timestamped price segments. A deterministic handler scenario also requires actual partial fills, cooldown refusals, and successful buyback recovery.
- `MainnetFork.t.sol`: adds a backed IMD claim donation, price-limited partial buyback, preservation of unused claims, subsequent batch, and donation sweep against the deployed manager and token.

Local tests use the vendored PoolManager implementation, a standard ERC-20 at IMD's specified address, genuine constructor-deployed NUKE tokens, and CREATE2-mined hooks. Only the transfer-failure tests mock external calls, to verify rollback; ordinary swap and batch tests do not mock the manager. No environment variables are changed.

Offline verification (artifacts stay in disposable scratch space):

```sh
forge build --offline --out test/scratch/out --cache-path test/scratch/cache
forge test --offline --out test/scratch/out --cache-path test/scratch/cache
```

Fork verification requires network access and is explicitly skipped when no fork is selected:

```sh
forge test --match-contract MainnetForkTest \
  --fork-url https://ethereum-rpc.publicnode.com --fork-block-number 26150564 \
  --no-storage-caching --out test/scratch/out --cache-path test/scratch/cache
```

The factory's Merkle distribution and deployment orchestration are outside this tests-only assignment. Claim donations are always funded through actual transfers and settlement; none of these tests substitutes a guessed deployment recipient or writes fabricated balances into the hook.

All three mainnet fork tests passed at block 26,150,564 during this assignment. The offline suite does not depend on a saved fork cache or any files under `test/scratch/`.
