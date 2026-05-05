# Architecture - The Pool V2.1

## Overview

The Pool V2.1 is a Uniswap v4 hook protocol for a WETH/USDC concentrated-liquidity pool on Arbitrum. It combines three mechanics:

1. A dynamic hook fee on AMM-routed swaps.
2. A reserve-sale path where the vault can post one-sided inventory that exact-input swappers may fill before the AMM leg.
3. An ERC-4626 vault that packages LP operations, reserve inventory, share accounting, optional zaps, and bootstrap rewards into depositor shares.

The current implementation is not the older four-contract V1 stack. V1 contracts and tests live under `src/archive-v1/` and `test/archive-v1/`. The current V2.1 stack is:

| Component | Source | Role |
|---|---|---|
| `BaseHook` | `src/BaseHook.sol` | Minimal Uniswap v4 hook base and PoolManager caller guard. |
| `DynamicFeeHookV2` | `src/DynamicFeeHookV2.sol` | Hook callbacks, dynamic fee routing, reserve-sale fills, reserve accounting, diagnostics. |
| `FeeDistributor` | `src/FeeDistributor.sol` | Splits hook fees between treasury/bootstrap and LP-side `poolManager.donate()`. |
| `LiquidityVaultV2` | `src/LiquidityVaultV2.sol` | ERC-4626 vault, LP position management, zaps, reserve offers, NAV protection, bootstrap auto-pokes. |
| `VaultOwnerController` | `src/VaultOwnerController.sol` | Safe-owned controller that exposes narrow reserve-keeper permissions. |
| `VaultLens` | `src/VaultLens.sol` | Read-only vault status and stats helper for frontends/keepers. |
| `SwapRouter02ZapAdapter` | `src/SwapRouter02ZapAdapter.sol` | Narrow Uniswap SwapRouter02 adapter used by vault zap entrypoints. |
| `BootstrapRewards` | `src/BootstrapRewards.sol` | Optional early-depositor bonus program funded from treasury inflows. |

Current production addresses are tracked in `docs/DEPLOYED_ADDRESSES.md`.

| Component | Arbitrum One address |
|---|---|
| `FeeDistributor` | `0x5757DA9014EE91055b244322a207EE6F066378B0` |
| `DynamicFeeHookV2` | `0x486579DE6391053Df88a073CeBd673dd545200cC` |
| `SwapRouter02ZapAdapter` | `0xdF9Ba20e7995A539Db9fB6DBCcbA3b54D026e393` |
| `LiquidityVaultV2` | `0xf79c2dc829cd3a2d8ceec353bdb1b2414ba1eee0` |
| `VaultOwnerController` | `0xa0e1580CAe87027D023E9dE94899346BFA383724` |
| `VaultLens` | `0x12e86890b75fdee22a35be66550373936d883551` |
| `BootstrapRewards` | `0x3E6Ed05c1140612310DDE0d0DDaAcCA6e0d7a03d` |

Operational production roles:

| Role | Arbitrum One address / status |
|---|---|
| Reserve desk write target | `VaultOwnerController` at `0xa0e1580CAe87027D023E9dE94899346BFA383724` |
| Hot reserve keeper EOA | `0x5cb4D906f0464B34C44d6555A770BF6af4a2CeFE` |
| Keeper allowlist status | `reserveKeepers(0x5cb4D906f0464B34C44d6555A770BF6af4a2CeFE) == true` |
| Controller owner / Safe | `0x75062AF3303d80eE4Cd33602866bFA4f63b485f5` |

```text
Swapper
  |
  v
Uniswap v4 PoolManager
  | beforeSwap / afterSwap
  v
DynamicFeeHookV2
  |-- beforeSwap: optional exact-input reserve fill via BeforeSwapDelta
  |-- afterSwap: dynamic hook fee on AMM-routed output side
  |
  +--> FeeDistributor
  |      |-- treasury/bootstrap share
  |      `-- LP share -> PoolManager.donate(poolKey, amount0, amount1, "")
  |
  `--> reserve escrow / proceeds owed for registered vault

LiquidityVaultV2
  |-- ERC-4626 USDC shares
  |-- balanced v4 liquidity via PositionManager + Permit2
  |-- optional zaps through SwapRouter02ZapAdapter
  |-- reserve offer lifecycle through DynamicFeeHookV2
  `-- BootstrapRewards poke on share movements

VaultOwnerController
  |-- Safe/multisig owner for all admin paths
  `-- hot keeper allowlist for typed reserve operations only

VaultLens + keeper exporter + Prometheus/Grafana
  `-- public/operator telemetry for TVL, share price, range state, reserve health, and freshness
```

## Contract Details

### `BaseHook`

`BaseHook` implements Uniswap v4's `IHooks` surface and enforces `onlyPoolManager` on callbacks. It also validates hook permissions in the constructor with `Hooks.validateHookPermissions`. Subclasses override only the callbacks they use; every unimplemented callback reverts with `HookNotImplemented()`.

### `DynamicFeeHookV2`

`DynamicFeeHookV2` extends `BaseHook`, `Ownable2Step`, and `ReentrancyGuard`. It enables these permission bits:

- `beforeSwap`
- `afterSwap`
- `beforeSwapReturnDelta`
- `afterSwapReturnDelta`

The CREATE2-mined hook address must encode those bits. The deploy script mines for low-byte flags `0xCC`.

#### Dynamic Fee Path

The V2 hook keeps the V1 dynamic fee idea but computes the final fee in `afterSwap` from the AMM-routed unspecified/output-side delta:

```text
base hook fee = output-side AMM delta * 25 bps
volatile hook fee = base hook fee * 1.5, when the per-pool price reference moved >= 1%
fee cap = output-side AMM delta * maxFeeBps / 10_000
charged fee = min(dynamic fee, fee cap)
```

Important fee state:

| Variable | Default | Notes |
|---|---:|---|
| `HOOK_FEE_BPS` | `25` | Base hook fee rate. |
| `maxFeeBps` | `50` | Owner-adjustable per-swap cap; hard max `1000`. |
| `VOLATILITY_THRESHOLD_BPS` | `100` | 1% price-reference movement threshold. |
| `VOLATILITY_FEE_MULTIPLIER` | `150` | 1.5x multiplier when threshold is hit. |
| `_lastSqrtPriceX96[poolId]` | `0` | Per-pool reference price. |
| `_lastSwapBlock[poolId]` | `0` | Prevents same-block reference refresh abuse. |
| `totalSwaps` | `0` | Incremented when hook logic is active. |
| `totalFeesRouted` | `0` | Cumulative hook fees sent to the distributor. |

`beforeSwap` calculates the volatility multiplier and stores it, the pool id, and an active flag in EIP-1153 transient storage. `afterSwap` reads and clears those slots, validates the pool id, calculates the fee from the actual swap delta, calls `poolManager.take()`, sends tokens to `FeeDistributor`, and returns the fee as `afterSwapReturnDelta`.

The hook tracks fee distribution failures without reverting the swap. If `feeDistributor.distribute()` reverts, the fee has already been transferred to the distributor, so the hook increments `failedDistribution[currency]` and emits `FeeDistributionFailed`. Operators recover by fixing the distributor state, calling `FeeDistributor.retryDistribute()` or `FeeDistributor.sweepUndistributed()`, then clearing the hook tally with `acknowledgeFailedDistribution()`.

#### Reserve-Sale Path

V2 adds a per-pool reserve-sale system. A registered vault can escrow one-sided inventory at the hook and quote it to exact-input swappers before the AMM leg.

Core reserve state:

| State | Meaning |
|---|---|
| `registeredVault[poolId]` | The single vault allowed to manage reserve offers for that pool. One-shot registration. |
| `offers[poolId]` | Active/inactive reserve offer, sell currency, remaining inventory, quote price, expiry, side, pricing mode. |
| `escrowedReserve[vault][currency]` | Vault inventory held by the hook. Still economically vault-owned. |
| `proceedsOwed[vault][currency]` | Claimable currency received from filled reserve sales. |
| `totalReserveFills` | Number of reserve fills. |
| `totalReserveSold` | Cumulative reserve inventory sold, in raw sell-currency units. |

Only the hook owner can call `registerVault(poolKey, vault)`, and each pool can be registered once in the current V2 hook. Once a vault is registered for a pool, it cannot be replaced by the existing contract. Replacing it would require a new hook deployment, a new pool, or a future hook version with an explicit migration path. Once registered, only that vault can create, cancel, or claim offers for the pool.

Offer creation supports two pricing modes:

| Mode | Intent | Fill gate |
|---|---|---|
| `PRICE_IMPROVEMENT` | Vault gives swappers a price at or better than the AMM marginal price. | Fill only when the AMM is at-or-worse than the vault quote. |
| `VAULT_SPREAD` | Vault monetizes spread when AMM spot is at-or-better than the vault quote. | Fill only when the AMM is favorable enough for the vault quote to capture spread. |

Reserve fills are exact-input only. The hook skips the reserve path for exact-output swaps, inactive offers, expired offers, direction mismatches, zero price, failed price gates, zero amounts, or `int128` delta overflow. When a fill succeeds, the hook:

1. Takes the swapper's input currency from PoolManager.
2. Settles the vault's sell currency back through PoolManager.
3. Decrements offer inventory and escrow.
4. Credits proceeds to `proceedsOwed`.
5. Emits `ReserveFilled`.
6. Returns a `BeforeSwapDelta` so the AMM leg only handles the remainder.

`getOfferHealth()` exposes the active flag, drift bps, escrow balances, proceeds balances, vault quote, and pool spot for keepers and dashboards. `getStats()` returns `(totalSwaps, totalFeesRouted, distributor, totalReserveFills, totalReserveSold)`.

### `FeeDistributor`

`FeeDistributor` is the only contract that should receive routed hook fees. `distribute(currency, amount)` requires `msg.sender == hook`.

Default split:

```text
treasuryShare = 20 / 100
LP share = 80 / 100
```

The owner may adjust `treasuryShare`, capped at `MAX_TREASURY_SHARE = 50`. The LP share is always the complement.

Distribution flow:

1. Validate the pool key has been set and the currency is either `poolKey.currency0` or `poolKey.currency1`.
2. Transfer the treasury/bootstrap share directly to `treasury`.
3. Donate the LP share back into the v4 pool using `sync -> transfer -> settle -> donate`.
4. Update `totalDistributed`, `totalToTreasury`, `totalToLPs`, and `distributionCount`.

The donated LP share is pool-level fee growth. It accrues to whichever LP positions are active and in range at the donation tick, pro rata by active liquidity. The vault is one LP wrapper; it does not receive a privileged donation stream.

Recovery functions:

- `retryDistribute(currency, amount)` re-runs accounting for tokens physically present in the distributor.
- `sweepUndistributed(currency, to, amount)` is a last-resort owner escape hatch for stuck pool currencies.

### `LiquidityVaultV2`

`LiquidityVaultV2` is an ERC-4626 vault whose asset is the configured deposit token, currently USDC on the V2.1 deployment. It can hold idle asset, idle other-token inventory, a v4 LP NFT position, reserve inventory escrowed at the hook, and reserve proceeds pending at the hook.

The vault is ERC-20-only. Native ETH pools and native ETH transfers are rejected; accidental native dust can only be recovered through `rescueNative()`.

#### ERC-4626 Share Accounting

`totalAssets()` includes:

- Idle asset balance.
- Asset-side value of the live v4 liquidity position.
- Other-token side of the live position quoted back to the vault asset.
- Idle other-token balance quoted back to the vault asset.
- Pending reserve proceeds owed by the hook.
- Reserve inventory escrowed at the hook.

Other-token idle/pending/escrow balances are quoted at a price clamped to the active tick range, while live LP amounts are valued at live spot. This keeps NAV continuous across reserve offer post, partial fill, full fill, claim, and cancel states.

The vault has a NAV deviation guard. `totalAssets()` quotes the non-asset side at pool spot, but entrypoints that mint or burn shares call `_bootstrapAndCheckNav()`. The first use bootstraps `navReferenceSqrtPriceX96`; later calls revert with `NAV_PRICE_DEVIATION()` if live spot differs from the reference by more than `maxNavDeviationBps` of price. The owner can re-anchor the reference with `refreshNavReference()` after a legitimate move.

#### Deposits, Zaps, And Liquidity

Plain `deposit()` and `mint()`:

1. Require pool configuration and `MIN_DEPOSIT = 1e6` asset units.
2. Check/initialize the NAV reference.
3. Pull reserve proceeds from the hook in both currencies.
4. Enforce `maxTVL` if set.
5. Mint ERC-4626 shares.
6. Try to deploy balanced v4 liquidity with available token balances.

`depositWithZap()` lets a depositor supply the vault asset, swap part of it into the other pool token through the configured zap router, deploy balanced liquidity, then mint shares from the net NAV delta produced by the operation. This prevents existing depositors from absorbing the new depositor's swap cost or slippage. User guards include `minOtherOut`, `minLiquidity`, `minSharesOut`, and `deadline`.

`withdraw()` and `redeem()` collect LP fees, remove proportional liquidity, and require enough vault asset to satisfy the request. If the vault holds value in the other token, `withdrawWithZap()` and `redeemWithZap()` can swap other-token inventory back to asset through the zap router before final transfer.

Liquidity operations use `VaultLP` and v4 `PositionManager` with Permit2 approvals. Deployment records actual spent amounts and minted liquidity; removal uses `removeLiquiditySlippageBps`, capped at 100 bps.

#### Reserve Operations

The vault owns the reserve lifecycle from the hook's perspective:

- `setReserveHook(newHook)` binds the hook and requires it to match `poolKey.hooks`.
- `offerReserveToHook()` and `offerReserveToHookWithMode()` escrow inventory at the hook.
- `cancelReserveOffer()` returns unfilled inventory.
- `collectReserveProceeds()` pulls one currency of proceeds back to the vault.
- `rebalanceOffer()` and `rebalanceOfferWithMode()` atomically cancel an existing offer if active, claim both proceeds currencies, and post a fresh offer.

Every deposit, mint, withdraw, and redeem also calls `_pullReserveProceedsBoth()` before share math so already-realized proceeds are included physically in the vault.

#### Bootstrap Rewards Integration

The vault can bind an optional `BootstrapRewards` contract. When set, every mint, burn, or transfer auto-pokes both affected share holders through `BootstrapRewards.poke(user)`. Pokes are wrapped in `try/catch`; a failing rewards contract emits `BootstrapPokeFailed` but cannot block deposits, withdrawals, or transfers.

### `VaultOwnerController`

`VaultOwnerController` is the owner-of-vault wrapper used for V2.1 operations. The Safe/multisig owns the controller. The controller owns the vault. Hot keepers can be allowlisted for typed reserve operations only:

- `offerReserveToHookWithMode()`
- `rebalanceOfferWithMode()`
- `cancelReserveOffer()`
- `collectReserveProceeds()`

Everything else goes through the Safe-only `executeVaultOwnerCall(bytes)` escape hatch: `setPoolKey`, `rebalance`, `setReserveHook`, `setBootstrapRewards`, `setZapRouter`, pause/unpause, ownership transfer, NAV reference updates, and similar owner operations.

The raw escape hatch rejects the reserve selectors above so reserve keeper activity always emits controller-level `ReserveKeeperCallExecuted` events.

Production ownership hierarchy:

```text
Safe/multisig
  -> owns VaultOwnerController
      -> owns LiquidityVaultV2
          -> remains registered vault in DynamicFeeHookV2

Hot keeper
  -> allowlisted in VaultOwnerController only for reserve operations
```

### `VaultLens`

`VaultLens` is a read-only helper for frontends and keepers.

`vaultStatus(vault)` returns:

- `UNCONFIGURED`
- `PAUSED`
- `IN_RANGE`
- `OUT_OF_RANGE`

`getVaultStats(vault)` returns TVL, share price scaled to `1e18`, depositor count, deployed assets, collected asset-token yield, and a legacy `feeDesc` string that is currently empty.

### `SwapRouter02ZapAdapter`

The zap adapter exposes the narrow `IZapRouter.swapExactInput()` surface expected by the vault and forwards to Uniswap SwapRouter02 `exactInputSingle`. The vault never accepts arbitrary router calldata. The adapter enforces a nonzero amount, nonzero recipient, live deadline, and `amountOutMinimum`.

### `BootstrapRewards`

`BootstrapRewards` is an optional early-depositor reward program. It can be configured as the `FeeDistributor.treasury` during a program window. It splits incoming payout-asset inflows between an epoch bonus pool and the real treasury, tracks eligible share-seconds with lazy `poke(user)` accounting, applies dwell/cap rules, and pays rewards through `claim(epoch)` after finalization.

Non-payout assets can be swept to the real treasury. Unclaimed epoch rewards can be swept after the claim window.

## Data Flows

### Swap With Optional Reserve Fill

```text
1. Swapper submits an exact-input swap through PoolManager.
2. PoolManager calls DynamicFeeHookV2.beforeSwap().
3. If a matching reserve offer is active, unexpired, direction-compatible, and price-gated:
   - hook absorbs part/all of the swapper input;
   - hook settles reserve output to the swapper;
   - hook records proceeds owed to the vault;
   - hook returns BeforeSwapDelta.
4. PoolManager routes the remaining swap amount through the AMM.
5. PoolManager calls DynamicFeeHookV2.afterSwap().
6. Hook computes the dynamic fee from the AMM-routed output-side delta.
7. Hook takes the fee, transfers it to FeeDistributor, and attempts distribution.
8. FeeDistributor sends treasury/bootstrap share and donates LP share back to the pool.
```

Exact-output swaps skip reserve fills and still receive normal hook fee logic on the AMM-routed swap.

### Vault Deposit

```text
deposit / mint / depositWithZap
  -> check pool configured, not paused, min deposit, NAV reference
  -> claim reserve proceeds in both currencies if pending
  -> enforce TVL cap
  -> optionally zap asset into other token
  -> mint shares using ERC-4626 or net-NAV-delta zap math
  -> deploy balanced v4 liquidity if possible
  -> auto-poke BootstrapRewards on share mint
```

### Vault Withdrawal

```text
withdraw / redeem / withdrawWithZap / redeemWithZap
  -> check NAV reference
  -> claim reserve proceeds in both currencies if pending
  -> collect LP fees
  -> remove proportional liquidity
  -> optionally zap other token back to asset
  -> burn shares and transfer asset
  -> auto-poke BootstrapRewards on share burn
```

### Reserve Offer Rotation

```text
keeper or Safe -> VaultOwnerController.rebalanceOfferWithMode()
  -> controller forwards typed call to LiquidityVaultV2
  -> vault checks active offer through hook.offerActive(poolKey)
  -> if active: cancel old offer and return inventory
  -> claim both proceeds currencies from hook
  -> approve hook for new inventory
  -> create fresh reserve offer with selected pricing mode
  -> emit vault and controller events for auditability
```

## Security And Operational Properties

| Property | Mechanism |
|---|---|
| Hook caller verification | `BaseHook.onlyPoolManager` on callbacks. |
| Hook address safety | CREATE2 salt mining for required v4 permission bits. |
| Reserve manager immutability | `DynamicFeeHookV2.registerVault()` is one-shot per `PoolId`. |
| Reserve caller control | Only registered vault can create, cancel, or claim offers. |
| Reserve fill constraints | Exact-input only; direction, expiry, price gate, zero-amount, and delta-bound checks. |
| Price-gate telemetry | `ReserveOfferStale` emitted when matched direction fails by more than 50 bps drift. |
| Fee cap | `maxFeeBps` default 50 bps, hard max 1000 bps. |
| Fee distribution DoS protection | Distributor failures do not revert swaps; unresolved amounts are tracked in `failedDistribution`. |
| LP donation scope | Donations accrue to all in-range LPs at the donation tick, not only the vault. |
| NAV manipulation guard | `navReferenceSqrtPriceX96` plus `maxNavDeviationBps` blocks share math under large spot deviations. |
| Reserve NAV continuity | `totalAssets()` counts pending proceeds and escrowed reserve inventory. |
| Native ETH rejection | Hook/vault/zap stack is ERC-20-only; native pools and direct ETH sends are rejected. |
| Vault pause | `Pausable` blocks deposits, withdrawals, and redemptions. |
| Reentrancy | `ReentrancyGuard` on distributor, vault, hook reserve/admin paths, controller, rewards. |
| Permit2 handling | Vault grants Permit2 approvals for PositionManager flows when configured. |
| Zap safety | Vault uses a narrow `IZapRouter`; adapter only forwards `exactInputSingle`. |
| Slippage/deadline controls | Liquidity removal slippage capped at 1%; tx deadline capped at 3600 seconds. |
| Keeper privilege separation | Hot keepers get reserve operations only; Safe retains all other vault owner powers. |
| Bootstrap safety | Rewards auto-pokes cannot DoS share movements due to `try/catch`. |

## Core Deployment And Ownership Hardening

Canonical V2.1 deployment uses `script/DeployHookV2AndVault.s.sol`.

Required environment values include:

```text
POOL_MANAGER
POS_MANAGER
TOKEN0
TOKEN1
ASSET_TOKEN
POOL_FEE
TICK_SPACING
INIT_SQRT_PRICE_X96
V2_TICK_LOWER
V2_TICK_UPPER
PERMIT2
TREASURY
SWAP_ROUTER_02 or ZAP_ROUTER
```

Optional values include:

```text
ZAP_POOL_FEE
PERFORMANCE_FEE_BPS   default 400
MAX_TVL               default 0
MAX_FEE_BPS           default 50
```

Deployment sequence:

1. Load pool, token, range, Permit2, treasury, zap, and fee config.
2. Precompute the `FeeDistributor` address from deployer nonce.
3. Mine a CREATE2 salt for `DynamicFeeHookV2` with required permission bits.
4. Deploy `FeeDistributor` with hook unset.
5. Deploy `DynamicFeeHookV2` with the mined salt.
6. Wire `distributor.setHook(hook)`.
7. Initialize the v4 pool and set the distributor pool key.
8. Deploy or reuse `SwapRouter02ZapAdapter`.
9. Deploy `LiquidityVaultV2`, set pool key, initial range, reserve hook, treasury, performance fee, and TVL cap.
10. Register the vault with `hook.registerVault(poolKey, vault)`.

Post-deploy ownership hardening:

1. Deploy `VaultOwnerController` with the Safe as controller owner.
2. Current vault owner calls `vault.transferOwnership(controller)`.
3. Call `controller.acceptVaultOwnership()`.
4. Safe calls `controller.setReserveKeeper(keeperEOA, true)`.
5. Keeper writes through `KEEPER_WRITE_TARGET=controller` while reads remain pointed at the vault, hook, and lens.

Run through the wrapper script where possible:

```powershell
.\script\deploy-ledger.ps1
```

Direct Foundry entrypoint:

```bash
forge script script/DeployHookV2AndVault.s.sol --tc DeployHookV2AndVault --rpc-url $RPC_URL --private-key $PK --broadcast
```

Related deployment scripts:

| Script | Purpose |
|---|---|
| `script/DeployController.s.sol` | Deploy or wire `VaultOwnerController`. |
| `script/DeployBootstrap.s.sol` | Deploy `BootstrapRewards`. |
| `script/DeployVaultResume.s.sol` | Resume/wire a deployed V2 vault. |
| `script/VerifyResumeDeploy.s.sol` | Verify resumed deployment state. |
| `script/SeedActiveLiquidity.s.sol` | Seed vault liquidity for fork/live checks. |
| `script/ForkE2E.s.sol` | Fork end-to-end exercise. |

Archived V1 deployment scripts live under `script/archive-v1/` and should not be used for the current V2.1 stack.

## Keeper And Telemetry

The keeper in `scripts/keeper/reserveKeeper.ts` reads VaultLens, hook health, offer details, reserve proceeds, escrow, and hook counters. In write mode it can call the controller reserve paths; in `READ_ONLY=true` mode it exports live Prometheus metrics without requiring a private key.

In controller mode, the keeper must not require `keeperEOA == vault.owner()`. The correct checks are `vault.owner() == KEEPER_WRITE_TARGET` and `controller.reserveKeepers(keeperEOA) == true`.

The current production hot reserve keeper EOA is `0x5cb4D906f0464B34C44d6555A770BF6af4a2CeFE`. It is the wallet that adjusts reserve offers through `offerReserveToHookWithMode`, `rebalanceOfferWithMode`, `cancelReserveOffer`, and `collectReserveProceeds`.

The public Grafana bundle lives under `scripts/keeper/grafana-public/` and is intentionally separate from the private operator dashboard. Public panels should focus on trust and investor-visible state: TVL, share price, depositors, data freshness, offer state, quote drift, reserve fills, reserve inventory, and settlement backlog.

## Test Architecture

| Suite | File | Coverage |
|---|---|---|
| Hook reserve unit | `test/DynamicFeeHookV2.t.sol` | Vault registration, reserve offer creation/cancel/claim, validation. |
| Fee distributor | `test/FeeDistributor.t.sol` | Split math, caps, hook-only access, retry/sweep recovery. |
| Vault V2 unit | `test/LiquidityVaultV2.t.sol` | ERC-4626 mechanics, zaps, NAV continuity, reserve hook binding, bootstrap auto-poke. |
| Controller unit | `test/VaultOwnerController.t.sol` | Keeper allowlist, typed reserve forwards, Safe escape hatch restrictions. |
| Bootstrap rewards | `test/BootstrapRewards.t.sol` | Epochs, dwell, caps, claims, sweeps, treasury forwarding. |
| V2 reserve integration | `test/IntegrationV2Reserve.t.sol` | Reserve fills coexisting with AMM swaps and fee routing. |
| Pricing modes | `test/ReservePricingMode.t.sol` | `PRICE_IMPROVEMENT` and `VAULT_SPREAD` gates in both swap directions. |
| Reserve invariants | `test/ReserveFillInvariants.t.sol` | Reserve accounting and exact-output skip behavior. |
| Reserve fuzz invariants | `test/ReserveFillFuzzInvariants.t.sol` | Stateful reserve offer/fill/cancel/claim invariants. |
| Reality checks | `test/RealityCheck.t.sol` | Human-readable reserve lifecycle, stale offers, fee distribution, health views. |
| Fork checks | `test/ResumeDeployFork.t.sol`, `test/LiquidityVaultV2Fork.t.sol` | Live/fork deployment state, VaultLens, zap adapter behavior. |

V1 tests remain under `test/archive-v1/` for history and regression reference only.

## Support Libraries And Interfaces

| File | Purpose |
|---|---|
| `src/libraries/VaultMath.sol` | NAV quote math, clamped quote pricing, price deviation checks. |
| `src/libraries/VaultLP.sol` | PositionManager action encoding for deploy, collect, and remove liquidity. |
| `src/libraries/LiquidityAmounts.sol` | Liquidity/amount conversions for v4 ranges. |
| `src/libraries/CurrencySettler.sol` | Currency settlement helper used by the hook. |
| `src/interfaces/IZapRouter.sol` | Minimal zap router interface consumed by `LiquidityVaultV2`. |

## V1 Archive Note

The old V1 `DynamicFeeHook` and `LiquidityVault` docs are no longer the canonical architecture. V1 did not include the V2 reserve-sale path, zap-aware fair deposits/withdrawals, NAV deviation guard, controller-owned keeper model, VaultLens telemetry, or BootstrapRewards integration. New integrations should target V2.1 addresses and source files only.