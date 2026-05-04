# Hook-Risk & Audit-Readiness Operator Runbook

**Status:** V2.1 production stack with V2.2 hardening primitives, refreshed 2026-05-04.

**Companion documents:**
[docs/DEPLOYED_ADDRESSES.md](DEPLOYED_ADDRESSES.md),
[docs/ARCHITECTURE.md](ARCHITECTURE.md),
[docs/BOOTSTRAP.md](BOOTSTRAP.md),
[docs/CODE-EXAMPLES.md](CODE-EXAMPLES.md),
[scripts/keeper/README.md](../scripts/keeper/README.md),
[audits/TSI-Audit-Scanner_2026-04-25.md](../audits/TSI-Audit-Scanner_2026-04-25.md),
[audits/TSI-Audit-Scanner_2026-04-27.md](../audits/TSI-Audit-Scanner_2026-04-27.md),
and [lib/VERSIONS.md](../lib/VERSIONS.md).

This runbook is the operator-facing companion to the audit reports. It covers:

1. The trust model for the deployed V2.1 contracts on Arbitrum One.
2. The attack surface introduced by dynamic hook fees, reserve offers, vault accounting, controller-owned operations, and BootstrapRewards.
3. The response playbooks for failed fee distribution, native ETH dust, NAV drift, reserve-offer maintenance, BootstrapRewards operations, keeper rotation, and emergency pause.

It is not a substitute for an independent human audit. The audit reports remain the authoritative record of findings; this document tells an operator what to monitor and what to do.

---

## 1. Production State

Current production addresses are tracked in [docs/DEPLOYED_ADDRESSES.md](DEPLOYED_ADDRESSES.md). The active Arbitrum One V2.1 set is:

| Component | Address |
|---|---|
| `FeeDistributor` | `0x5757DA9014EE91055b244322a207EE6F066378B0` |
| `DynamicFeeHookV2` | `0x486579DE6391053Df88a073CeBd673dd545200cC` |
| `SwapRouter02ZapAdapter` | `0xdF9Ba20e7995A539Db9fB6DBCcbA3b54D026e393` |
| `LiquidityVaultV2` | `0xf79c2dc829cd3a2d8ceec353bdb1b2414ba1eee0` |
| `VaultOwnerController` | `0xa0e1580CAe87027D023E9dE94899346BFA383724` |
| `VaultLens` | `0x12e86890b75fdee22a35be66550373936d883551` |
| `BootstrapRewards` | `0x3E6Ed05c1140612310DDE0d0DDaAcCA6e0d7a03d` |

Canonical pool and infra:

| Item | Value |
|---|---|
| Chain | Arbitrum One, chainid `42161` |
| Pair | WETH / native USDC |
| Pool fee tier | `500` fee units = 5 bps |
| Tick spacing | `60` |
| Active range | `[-199020, -198840]` |
| PoolManager | `0x360e68faccca8ca495c1b759fd9eee466db9fb32` |
| PositionManager | `0xd88f38f930b7952f2db2432cb002e7abbf3dd869` |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |
| WETH | `0x82aF49447D8a07e3bd95BD0d56f35241523fBab1` |
| USDC | `0xaf88d065e77c8cC2239327C5EDb3A432268e5831` |

Production ownership hierarchy:

```text
Safe / multisig
  -> owns VaultOwnerController
      -> owns LiquidityVaultV2
          -> remains the registered vault in DynamicFeeHookV2

Hot reserve keeper
  -> allowlisted in VaultOwnerController
  -> can call only typed reserve operations
```

BootstrapRewards is wired as:

```text
FeeDistributor.treasury = BootstrapRewards
BootstrapRewards.realTreasury = Ledger
LiquidityVaultV2.bootstrapRewards = BootstrapRewards
```

Program defaults are documented in [docs/BOOTSTRAP.md](BOOTSTRAP.md): 180 days, 6 x 30-day epochs, 7-day finalization delay, 90-day claim window, 50% of processed USDC treasury inflow to the bonus pool, 10,000 USDC per-epoch cap, deployment-time 25,000 USDC per-wallet share cap, and deployment-time 100,000 USDC global share cap.

---

## 2. Trust Model

### Contracts In Scope

| Contract | Address class | Trust and owner powers |
|---|---|---|
| [DynamicFeeHookV2](../src/DynamicFeeHookV2.sol) | CREATE2 salt-mined hook address with `beforeSwap`, `afterSwap`, `beforeSwapReturnDelta`, and `afterSwapReturnDelta` flags | `Ownable2Step`. Owner can register one vault per pool, update distributor, acknowledge failed distribution tallies, and set `maxFeeBps` up to 1000 bps. |
| [FeeDistributor](../src/FeeDistributor.sol) | Normal deploy | `Ownable2Step`. Owner can set hook, pool key, treasury, treasury share up to 50%, retry stuck distribution, and sweep stuck pool currencies as a last resort. |
| [LiquidityVaultV2](../src/LiquidityVaultV2.sol) | Normal deploy, currently owned by `VaultOwnerController` | `Ownable2Step`, `Pausable`, `ReentrancyGuard`. Owner can pause, set one-shot pool key, set reserve hook, set zap router, set BootstrapRewards, refresh NAV reference, set TVL cap, set performance fee up to 20%, set treasury, and rescue native ETH dust. |
| [VaultOwnerController](../src/VaultOwnerController.sol) | Normal deploy | Safe-owned owner wrapper for the vault. Hot keepers can call only typed reserve operations; all other vault-owner calls require Safe ownership through `executeVaultOwnerCall(bytes)`. |
| [BootstrapRewards](../src/BootstrapRewards.sol) | Normal deploy | `Ownable2Step`. Owner can update real treasury and sweep non-payout assets. Inflow, poke, claim, and epoch sweep paths are permissionless under program rules. |
| [VaultLens](../src/VaultLens.sol) | Normal deploy | Read-only helper for frontends and keepers. No privileged operator path. |
| [SwapRouter02ZapAdapter](../src/SwapRouter02ZapAdapter.sol) | Normal deploy | Narrow adapter to Uniswap SwapRouter02 `exactInputSingle`; vault user guards (`minOtherOut`, `minSharesOut`, deadlines) still define acceptable slippage. |

### Core Assumptions

- **Owner is honest-but-fallible.** Admin actions are intentionally explicit, evented, and mostly behind `Ownable2Step` or the Safe-owned controller. The owner can pause and tune parameters, but cannot directly drain depositor ERC-20 assets through a generic rescue path.
- **The registered vault is sticky.** `DynamicFeeHookV2.registerVault(poolKey, vault)` is one-shot per pool. Replacing the vault while keeping the same hook/pool is not available in this version.
- **The hot keeper is intentionally narrow.** A compromised keeper can post, rebalance, cancel, or collect reserve offers through `VaultOwnerController`; it cannot pause/unpause, change fees, change treasury, set pool key, set zap router, set reserve hook, set BootstrapRewards, transfer vault ownership, or refresh NAV.
- **Fee distribution is non-blocking.** Hook swaps must not revert because the distributor is misconfigured. The hook transfers the fee to the distributor first, calls `distribute()`, and records `failedDistribution[currency]` if the call reverts.
- **Reserve offers are vault-initiated.** Only the registered vault can escrow inventory, cancel offers, or claim reserve proceeds for its pool. The hook cannot sell inventory that the vault did not escrow.
- **NAV reference is an operator guardrail.** `navReferenceSqrtPriceX96` is the reference for the entrypoint deviation guard. First use can bootstrap it; later owner refreshes should happen only after a legitimate market move.
- **BootstrapRewards is bounded.** It does not mint a token or promise yield. It splits only processed USDC payout-asset inflows above tracked bonus pools, and all reward accounting is capped by epoch, wallet, and global share-second limits.

### External Trust

- Uniswap v4 `PoolManager`, `PositionManager`, Universal Router / SwapRouter02, Permit2, and v4 pool mechanics.
- OpenZeppelin v5 `ERC4626`, `Ownable2Step`, `Pausable`, `ReentrancyGuard`, `SafeERC20`.
- Native USDC and WETH token behavior on Arbitrum.
- Keeper RPC correctness and public telemetry availability.

---

## 3. Attack Surface Map

### DynamicFeeHookV2

| Surface | Who can call | Invariants enforced |
|---|---|---|
| `beforeSwap` / `afterSwap` | `onlyPoolManager` | Exact-input reserve fills are sign-correct, price-gated, direction-gated, expiry-aware, inventory-bounded, and `int128`-bounded. Hook fee is charged on the AMM-routed unspecified-currency delta in `afterSwap`. |
| `createReserveOffer` / `createReserveOfferWithMode` | registered vault, `nonReentrant` | One active offer per pool; valid pool key; sell currency is one of the pool currencies; price within v4 bounds; fee-on-transfer tokens rejected by balance snapshot. |
| `cancelReserveOffer` | registered vault, `nonReentrant` | Deactivates offer and returns unfilled escrow to the vault. |
| `claimReserveProceeds` | registered vault, `nonReentrant` | Pays only accrued `proceedsOwed[vault][currency]`. |
| `acknowledgeFailedDistribution` | hook owner | Bookkeeping-only decrement after distributor-side recovery; underflow guarded. |
| `setMaxFeeBps`, `setFeeDistributor`, `registerVault` | hook owner | Fee cap has hard limit of 1000 bps; vault registration is one-shot per pool. |

Conservation invariants are covered by [test/ReserveFillFuzzInvariants.t.sol](../test/ReserveFillFuzzInvariants.t.sol):

1. `hookBalance[c] >= escrowedReserve[vault][c] + proceedsOwed[vault][c]`
2. `ghostEscrowedIn[c] = ghostReturned[c] + ghostSold[c] + escrow[c]`
3. `ghostProceedsAccrued[c] = ghostClaimed[c] + proceeds[c]`
4. `totalReserveSold == sum(ghostSold[c])`
5. `offerActive` implies on-chain offer is active and `sellRemaining > 0`

### FeeDistributor

| Surface | Who can call | Invariants enforced |
|---|---|---|
| `distribute` | only configured hook | Splits hook fees into treasury/bootstrap share and LP donation share; only pool-key currencies are accepted. |
| `retryDistribute` | owner, `nonReentrant` | Replays distribution for tokens physically present at the distributor. |
| `sweepUndistributed` | owner | Last-resort recovery for stuck pool currencies only. |
| `setHook`, `setPoolKey`, `setTreasury`, `setTreasuryShare` | owner | Treasury cannot be zero; treasury share capped at 50%. |

Default production split is 20% treasury/bootstrap and 80% LP donation. The LP donation is pool-level fee growth and is captured pro rata by active in-range LP liquidity; the vault is not privileged over other in-range LPs.

### LiquidityVaultV2

| Surface | Who can call | Invariants enforced |
|---|---|---|
| `deposit`, `mint`, `depositWithZap`, `withdraw`, `redeem`, zap withdrawals | anyone, `whenNotPaused` | ERC-4626 share math with `_decimalsOffset() = 6`, minimum deposit, max TVL, NAV deviation guard, user slippage/deadline guards, reserve proceeds pulled before share math. |
| `setPoolKey` | owner, one-shot | Permanent pool selection; cannot be repointed. |
| `setReserveHook` | owner | Non-zero hook must be a contract and must equal `poolKey.hooks`. |
| `setZapRouter` | owner | Non-zero router must be a contract. |
| `setBootstrapRewards` | owner | Non-zero rewards target must be a contract; vault share moves auto-poke with try/catch. |
| `refreshNavReference`, `setMaxNavDeviationBps` | owner | Re-anchor spot after legitimate moves; deviation cap cannot exceed 500 bps. |
| `setPerformanceFeeBps`, `setMaxTVL`, `setTreasury`, slippage/deadline setters | owner | Performance fee capped at 2000 bps; treasury rejects zero; remove-liquidity slippage capped at 100 bps; deadline capped at 3600 s. |
| `offerReserveToHookWithMode`, `rebalanceOfferWithMode`, `cancelReserveOffer`, `collectReserveProceeds` | vault owner; in production forwarded through `VaultOwnerController` | Reserve inventory lifecycle; typed controller paths emit controller-level keeper audit events. |
| `pause`, `unpause`, `rescueNative` | owner | Pauses user entrypoints; native ETH dust rescue only, no ERC-20 rescue path for depositor assets. |

### VaultOwnerController

| Surface | Who can call | Invariants enforced |
|---|---|---|
| `setReserveKeeper` | Safe/controller owner | Adds or revokes hot keeper addresses; zero address rejected. |
| `offerReserveToHookWithMode`, `rebalanceOfferWithMode`, `cancelReserveOffer`, `collectReserveProceeds` | Safe owner or allowlisted keeper | Only typed reserve paths; each emits `ReserveKeeperCallExecuted`. |
| `executeVaultOwnerCall(bytes)` | Safe/controller owner | Generic vault-owner escape hatch for non-reserve admin only; reserve selectors are rejected with `UseTypedReservePath`. |
| `acceptVaultOwnership` | permissionless, after nomination | Completes the vault's two-step ownership transfer to the controller. |

### BootstrapRewards

| Surface | Who can call | Invariants enforced |
|---|---|---|
| `pullInflow` | anyone | Processes only payout-asset balance above tracked unclaimed bonus pools; non-active program windows forward all processed USDC to real treasury; active epochs respect bonus share and per-epoch cap. |
| `poke` | anyone | Lazy, conservative share-second accounting; intervals split across epoch boundaries; per-wallet and global caps enforced. |
| `claim` | eligible user | Calls `_poke` first; requires finalized epoch, open claim window, unclaimed share-seconds, and nonzero payout. |
| `sweepEpoch` | anyone | Sweeps unclaimed payout asset to real treasury only after the claim window closes. |
| `sweepToken` | owner | Sweeps non-payout tokens only; cannot sweep USDC payout asset. |
| `setRealTreasury` | owner | Real treasury cannot be zero. |

---

## 4. Operator Runbook

### 4.1 New Deployment / Redeploy Checklist

Use the scripts in [script/](../script/) as the executable source of truth. For any future redeploy, update [docs/DEPLOYED_ADDRESSES.md](DEPLOYED_ADDRESSES.md) before pointing frontends or keepers at new contracts.

1. Mine the hook salt so the final address encodes `BEFORE_SWAP`, `AFTER_SWAP`, `BEFORE_SWAP_RETURNS_DELTA`, and `AFTER_SWAP_RETURNS_DELTA`.
2. Deploy `FeeDistributor` with temporary safe treasury and `hook = address(0)`.
3. Deploy `DynamicFeeHookV2(poolManager, distributor, owner)` at the mined salt.
4. Set `FeeDistributor.hook = hook` and configure the pool key before live fee routing.
5. Deploy `SwapRouter02ZapAdapter`, `LiquidityVaultV2`, `VaultLens`, and `VaultOwnerController`.
6. Configure the vault: pool key, reserve hook, zap router, initial ticks, max TVL, slippage/deadline, treasury, and performance fee.
7. Register the vault in the hook. Registration is one-shot for that pool.
8. Seed or refresh the NAV reference before public deposits. A founder seed deposit is recommended.
9. Deploy and wire `BootstrapRewards` if the program is active: distributor treasury to BootstrapRewards, BootstrapRewards real treasury to Ledger/Safe, vault BootstrapRewards pointer to BootstrapRewards.
10. Transfer vault ownership to `VaultOwnerController`, call `acceptVaultOwnership`, and set only the required reserve keepers.
11. Run keeper in `READ_ONLY=true` mode first, then `DRY_RUN=true`, then live writes only after offer health and ownership checks pass.
12. Publish updated frontend and keeper env values from [docs/DEPLOYED_ADDRESSES.md](DEPLOYED_ADDRESSES.md).

### 4.2 Failed Fee Distribution

**Symptom:** `FeeDistributionFailed(currency, amount)` from the hook, nonzero `hook.failedDistribution(currency)`, or keeper/Grafana unresolved-fee alert.

**Diagnosis:** In normal production flow the hook already transferred fee tokens to `FeeDistributor`, then `distribute(currency, amount)` reverted. The hook records the amount so operators can reconcile it without blocking swaps.

**Recovery:**

1. Fix the distributor cause: wrong hook, missing pool key, bad treasury/bootstrap target, unsupported currency, or downstream transfer/donate issue.
2. Check distributor token balance for the failed currency.
3. If balance is sufficient, call `FeeDistributor.retryDistribute(currency, amount)` from the distributor owner.
4. If distribution is intentionally bypassed, call `FeeDistributor.sweepUndistributed(currency, to, amount)` only for pool-key currencies and record the reason.
5. After the tokens have been reconciled at the distributor, call `DynamicFeeHookV2.acknowledgeFailedDistribution(currency, amount)` to clear the hook tally.
6. Do not clear the hook tally before physical token recovery is complete.

### 4.3 Native ETH Dust At Vault

**Symptom:** `address(vault).balance > 0`.

**Diagnosis:** The vault rejects direct native ETH through `receive()` and `fallback()`. Any ETH balance is unintended dust, typically forced by EVM mechanics.

**Recovery:** Because the controller owns the vault in production, the Safe should call `VaultOwnerController.executeVaultOwnerCall(abi.encodeCall(vault.rescueNative, (to, amount)))`. Emit and archive the transaction hash; native ETH dust is not part of share NAV.

### 4.4 NAV Anchor Drift / Deviation Guard

**Symptom:** Deposits, mints, withdrawals, or redeems revert with `NAV_PRICE_DEVIATION` / `NAV_PRICE_DEVIATION()`.

**Diagnosis:** The live pool spot moved more than `maxNavDeviationBps` from `navReferenceSqrtPriceX96`. This can be legitimate market movement or active manipulation.

**Recovery:**

1. Confirm the move with off-chain telemetry: block-by-block spot, reference price, pool depth, current range, recent swaps, and external WETH/USDC price.
2. If the move is legitimate, have the Safe call `refreshNavReference()` through `VaultOwnerController.executeVaultOwnerCall`.
3. If manipulation is suspected, do not refresh. Pause the vault through the controller, wait for arbitrage/market normalization, then refresh and unpause.
4. The deviation cap can be tightened through `setMaxNavDeviationBps`; it cannot be raised above 500 bps.

### 4.5 Reserve Offer Maintenance

**Posting policy:** Steady-state LP-yield inventory should use `VAULT_SPREAD` through controller-forwarded mode-aware functions:

```text
VaultOwnerController.offerReserveToHookWithMode(..., ReservePricingMode.VAULT_SPREAD)
VaultOwnerController.rebalanceOfferWithMode(..., ReservePricingMode.VAULT_SPREAD)
```

Legacy no-mode vault functions default to `PRICE_IMPROVEMENT` for ABI compatibility. Do not use them for steady-state yield inventory.

**Direction rule:**

```text
Vault sells currency1 (USDC) -> fillable only on zeroForOne swaps
Vault sells currency0 (WETH) -> fillable only on oneForZero swaps
```

**VAULT_SPREAD quote guide:**

| Sell currency | Fill gate | Suggested `vaultSqrtPriceX96` |
|---|---|---|
| `currency1` / USDC | `poolSqrtP >= vaultSqrtP` | `poolSqrtP * (1 - spread / 2)` |
| `currency0` / WETH | `poolSqrtP <= vaultSqrtP` | `poolSqrtP * (1 + spread / 2)` |

Typical spreads are 10-100 bps. Wider spreads earn more per fill but fill less often. Rebalance when `getOfferHealth(...).driftBps` exceeds the keeper drift band, commonly 50 bps.

**Expired or stale offer:** The hook skips expired offers but does not clear the raw storage `active` flag automatically. Dashboards and keepers must distinguish raw active, expired, and fillable states. Rebalance or cancel through `VaultOwnerController`.

**Cancellation:** Use `VaultOwnerController.cancelReserveOffer(sellCurrency)`. Proceeds already accrued survive cancellation; pull them with `collectReserveProceeds(currency)` or let the next rebalance claim both currencies.

**Keeper write target:** The production keeper should use:

```env
VAULT=0xf79c2dc829cd3a2d8ceec353bdb1b2414ba1eee0
VAULT_LENS=0x12e86890b75fdee22a35be66550373936d883551
HOOK=0x486579DE6391053Df88a073CeBd673dd545200cC
KEEPER_WRITE_TARGET=0xa0e1580CAe87027D023E9dE94899346BFA383724
```

For public telemetry, use `READ_ONLY=true`, `LOOP=true`, and `METRICS_PORT=9464`. This performs real chain reads and exposes Prometheus metrics without loading `KEEPER_PRIVATE_KEY` or evaluating write actions. `DRY_RUN=true` is optional but redundant when `READ_ONLY=true`.

### 4.6 BootstrapRewards Operations

**Inflow:** `pullInflow()` is permissionless and should be called by keeper/UI automation when USDC accumulates on BootstrapRewards. It processes only payout-asset balance above tracked unclaimed bonus pools.

**Foreign tokens:** If hook treasury fees arrive in WETH or another non-payout asset, they do not fund USDC rewards. The BootstrapRewards owner can call `sweepToken(token)` to forward non-USDC assets to real treasury.

**Pokes:** The vault auto-pokes on share mint, burn, and transfer, but frontends or keepers can call `poke(user)` before epoch finalization or claims. Poke failures from the vault are caught and emit `BootstrapPokeFailed`; they must not block vault accounting.

**Claims:** Users can claim only after epoch end plus 7-day finalization delay and only within the 90-day claim window. `claim(epoch)` pokes the caller first.

**Sweeps:** After the claim window closes, anyone can call `sweepEpoch(epoch)` to return unclaimed USDC to real treasury.

### 4.7 Emergency Pause / Rotation

| Scenario | Action |
|---|---|
| Hook salt-mined address compromise or bad hook behavior | Pause the vault through `VaultOwnerController.executeVaultOwnerCall`. There is no in-place hook rotation; plan redeploy/migration. |
| Distributor misconfiguration or compromise | Pause if user funds are at risk. Rotate treasury or hook through distributor owner. Existing hook swaps soft-fail into `failedDistribution` until distributor recovery. |
| BootstrapRewards failure | Vault share movement should continue because auto-pokes are wrapped in try/catch. Fix rewards contract state, poke affected users, or unbind rewards through controller if necessary. |
| Hot keeper key compromise | Revoke with `VaultOwnerController.setReserveKeeper(keeper, false)`, cancel/rebalance any suspicious offer, rotate the key, and review `ReserveKeeperCallExecuted` events. |
| Safe/controller owner compromise | Use `Ownable2Step` ownership transfer/acceptance from a secure Safe before attacker acceptance. If attacker controls accepted owner, pause/redeploy may be the only remaining path. |
| Treasury key compromise | Rotate distributor treasury, vault treasury, and BootstrapRewards real treasury to a fresh Safe. |

---

## 5. Monitoring Signals

| Source | Signal | Threshold / action |
|---|---|---|
| `hook.FeeDistributionFailed` | Any emission | Page operator; reconcile distributor balance and clear tally only after recovery. |
| `hook.failedDistribution(c)` | Nonzero | Reconcile within 24 hours. |
| `hook.getOfferHealth` | Raw active, expired, drift, escrow, proceeds | Rebalance when stale/expired or drift exceeds keeper band. |
| `hook.ReserveOfferStale` | Any emission | Recompute quote and rebalance if still profitable. |
| Hook ERC-20 balance vs escrow/proceeds | Balance below `escrowedReserve + proceedsOwed` | Never expected; page immediately. |
| `VaultOwnerController.ReserveKeeperCallExecuted` | Keeper reserve write | Audit every keeper write; unexpected caller means revoke immediately. |
| `vault.NavReferenceRefreshed` | More than one refresh per 24h | Review price source, range, and deviation cap. |
| Live spot vs NAV reference | Above 80% of cap | Warn; user entrypoints will revert near 100% of cap. |
| `vault.balance` native ETH | Greater than zero | Rescue dust and log forensics. |
| `BootstrapRewards.InflowReceived` | New USDC inflow split | Verify bonus/treasury split and epoch cap. |
| `BootstrapRewards.BonusPoolCapped` | Any emission | Expected only when epoch cap is hit; verify overflow went to real treasury. |
| `BootstrapRewards.Claimed` / `EpochSwept` | Claim/sweep activity | Watch for claim-window timing and unclaimed balance. |
| Keeper Prometheus metrics | stale scrape, RPC errors, expired/fillable mismatch | Alert; public Grafana should not require a private key. |

---

## 6. Audit-Readiness Summary

| Item | Status |
|---|---|
| V2.1 Tier-1 findings and first-deposit donation hardening | Fixed in current V2 stack. |
| Volatility-reference freeze residual | Mitigated by per-pool reference and same-block refresh guard. |
| Reserve-fill conservation coverage | Covered by deterministic tests plus 5 invariant functions in [test/ReserveFillFuzzInvariants.t.sol](../test/ReserveFillFuzzInvariants.t.sol). |
| NAV anchor drift | Fixed with `MAX_NAV_DEVIATION_CAP = 500` and owner-only refresh. |
| Native ETH hygiene | Fixed by reverting receive/fallback and owner-only `rescueNative`. |
| Failed distribution handling | Fixed by soft-fail hook accounting plus distributor retry/sweep recovery. |
| Bootstrap auto-poke | Implemented in vault share movement path with try/catch. |
| Controller ownership | Implemented via [src/VaultOwnerController.sol](../src/VaultOwnerController.sol), typed keeper paths, and Safe-only escape hatch. |
| BootstrapRewards | Implemented and documented; [test/BootstrapRewards.t.sol](../test/BootstrapRewards.t.sol) has 27 top-level tests. |
| Test inventory | 166 top-level `test*` functions plus 5 invariant functions in top-level repo tests; invariant profile is 256 runs x 15 depth. |
| CI | [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) runs build and non-fork tests on push/PR to `main`. |
| Vendored dependency provenance | [lib/VERSIONS.md](../lib/VERSIONS.md) records pinned versions and unresolved TO-PIN rows. |

### Known Operational Caveats

- **Human audit trigger remains important.** The README documents the independent human-audit trigger at 100,000 USDC TVL.
- **Founder seed deposit remains recommended.** `_decimalsOffset() = 6` and `minSharesOut` mitigate first-deposit donation griefing, but a seed deposit improves precision and operational confidence.
- **Hook address is permanent for its flag set.** A future hook-flag change requires redeploy and pool migration.
- **Vault registration is one-shot.** A vault redeploy requires a new hook/pool path or a future migration-capable hook.
- **BootstrapRewards is a bounded promotional rebate.** It depends on processed USDC treasury inflow and does not guarantee yield.
- **Read-only telemetry is intentionally separate from write keepers.** Public Grafana should run through `READ_ONLY=true` metrics, not a private keeper key.

### Stack Rating

**A.** The current stack has explicit accounting for reserve escrow/proceeds, bounded fee controls, controller-scoped keeper permissions, non-blocking distribution recovery, NAV deviation controls, and bounded BootstrapRewards accounting. Remaining risk is operational: owner/key management, keeper discipline, live range management, external Uniswap/token dependencies, and the still-recommended third-party human audit at the documented TVL threshold.