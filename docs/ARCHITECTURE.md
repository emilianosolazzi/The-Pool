# Architecture — DeFi Hook Protocol

## Overview

The DeFi Hook Protocol is a Uniswap v4 hook system that attaches a dynamic fee layer to a concentrated-liquidity pool and automatically routes collected fees into an ERC-4626 yield vault. The system is composed of four Solidity contracts that interact in a strict dependency chain.

```
Swapper ──► Uniswap v4 PoolManager
                   │ beforeSwap / afterSwap
                   ▼
           DynamicFeeHook           ← hook registered on PoolKey
                   │ distribute()
                   ▼
           FeeDistributor
            ├─ 20% ──► Treasury address
            └─ 80% ──► poolManager.donate()  (LP fee growth)
                              │ collectYield / withdraw / rebalance
                              ▼
                       LiquidityVault  (ERC-4626)
                              │ modifyLiquidities()
                              ▼
                    v4-periphery PositionManager
```

---

## Contracts

### `BaseHook` (`src/BaseHook.sol`)

Minimal abstract base implementing `IHooks`. Provides:

- `onlyPoolManager` modifier — all hook callbacks revert if not called by the registered `PoolManager`.
- `Hooks.validateHookPermissions` called in the constructor — ensures the hook's deployment address encodes the correct permission bits (Uniswap v4 requirement).
- Default `revert HookNotImplemented()` for every callback; subclasses override only what they need.

### `DynamicFeeHook` (`src/DynamicFeeHook.sol`)

Extends `BaseHook` and `Ownable2Step`. Activates `beforeSwap` and `afterSwap` callbacks.

**Fee computation (beforeSwap)**

1. Base fee: `amountIn × 30 BPS`.
2. Volatility multiplier: if the pool's `sqrtPriceX96` moved ≥ 1 % since the previous swap, the fee is scaled by **1.5×**.
3. Cap: fee is clamped to `maxFeePerSwap` (configurable by the owner, default `0.02 ETH`).
4. The fee amount and currency are written to **EIP-1153 transient storage** (`TSTORE`) so no state change crosses the callback boundary.

**Fee collection (afterSwap)**

1. Reads fee and currency from transient storage (`TLOAD`), then zeroes both slots.
2. Pulls the fee from the pool via `poolManager.take()`.
3. Approves and calls `feeDistributor.distribute()`.
4. Emits `FeeRouted` and accumulates `totalSwaps` / `totalFeesRouted`.

**Key state**

| Variable | Type | Notes |
|---|---|---|
| `maxFeePerSwap` | `uint256` | Owner-adjustable cap |
| `lastSqrtPriceX96` | `uint160` | Inter-swap price tracker for volatility detection |
| `lastSwapBlock` | `uint256` | Block of last price-reference update; prevents same-block sandwich resets |
| `feeDistributor` | `IFeeDistributor` | Replaceable by owner |
| `totalSwaps` | `uint256` | Monotonically increasing counter |
| `totalFeesRouted` | `uint256` | Cumulative fees sent to distributor |

**Anti-sandwich protection**

`lastSqrtPriceX96` is updated in `afterSwap` only when `block.number > lastSwapBlock`. An attacker cannot reset the reference price with a cheap same-block swap to suppress the 1.5× volatility multiplier on a subsequent exploit swap within the same block.

### `FeeDistributor` (`src/FeeDistributor.sol`)

Extends `Ownable2Step` and `ReentrancyGuard`. Single entry point: `distribute(currency, amount)`.

**Split logic**

```
Treasury  =  amount × 20 / 100
LPs       =  amount − Treasury
```

The LP portion is donated back to the pool's fee-growth via:

```
poolManager.sync(currency)
currency.transfer(poolManager, lpAmount)
poolManager.settle()
poolManager.donate(poolKey, amount0, amount1, "")
```

This feeds `feeGrowthGlobal` in the v4 `PoolManager`, which accrues to all in-range LP positions proportionally.

**Access control**

- `distribute()` is gated to `msg.sender == hook` — only the registered hook can trigger fee routing.
- `setHook()` / `setTreasury()` / `setPoolKey()` are owner-only (with `Ownable2Step` two-step transfer).

### `LiquidityVault` (`src/LiquidityVault.sol`)

Extends `ERC4626`, `Ownable2Step`, `ReentrancyGuard`, and `Pausable`. Implements the yield-bearing side of the protocol.

**ERC-4626 accounting**

```
totalAssets() = balanceOf(vault) + assetsDeployed
```

`assetsDeployed` is the token-denominated value of assets currently held in the active concentrated-liquidity position. When yield is collected, the vault's asset balance increases → share price rises → existing shares appreciate.

**Deposit flow**

```
deposit(assets, receiver)          [whenNotPaused]
  └── TVL cap check (if maxTVL > 0)
  └── super.deposit()              // mint shares at current share price
  └── _deployLiquidity(assets)     // open or increase a v4 position
```

**Withdraw flow**

```
withdraw(assets, receiver, owner)  [whenNotPaused]
  └── _collectYield()              // harvest any accrued fees from the position
  └── _removeLiquidity(proportion) // remove the pro-rata slice of the position
  └── super.withdraw()             // burn shares, transfer asset token
```

**Redeem flow**

```
redeem(shares, receiver, owner)    [whenNotPaused]
  └── _collectYield()              // harvest fees
  └── _removeLiquidity(proportion) // proportional removal
  └── super.redeem()               // burn shares, transfer asset token
```

**Yield collection**

`_collectYield()` calls `modifyLiquidities(DECREASE_LIQUIDITY 0)` — a zero-liquidity decrease that triggers the position manager to flush accrued fee tokens to the vault. The vault:

1. Measures `balanceAfter − balanceBefore` of the asset token.
2. Checks the other currency's balance delta (guarded by `.code.length > 0` to skip sentinels) and records it in `currency1YieldCollected`.
3. Deducts the performance fee from the asset-token yield and transfers it to `treasury`.
4. Credits the net yield to `totalYieldCollected`.

**Performance fee**

Owner sets `performanceFeeBps` (max 2 000 = 20%). On each yield collection the fee is deducted from newly harvested asset-token yield and sent to `treasury` before the remainder is credited to depositors. Default is 0 (no fee).

**Concentrated liquidity position**

**Key state**

| Variable | Default | Notes |
|---|---|---|
| `tickLower` | −230 270 | Owner-adjustable via `rebalance` |
| `tickUpper` | −69 082 | Owner-adjustable via `rebalance` |
| `treasury` | deployer | Receives performance fees; updatable by owner |
| `performanceFeeBps` | 0 | Fee on yield; max 2 000 (20%) |
| `maxTVL` | 0 | Deposit ceiling in asset units; 0 = unlimited |
| `currency1YieldCollected` | 0 | Cumulative non-asset-token yield collected |
| `totalYieldCollected` | 0 | Cumulative net asset-token yield credited to depositors |

Liquidity is computed from `LiquidityAmounts.getLiquidityForAmount0(sqrtPrice, sqrtPriceUpper, amount)`. Slippage on removal is protected via `getAmountsForLiquidity` with a 0.5 % haircut (`× 995 / 1000`).

**Rebalance**

```
rebalance(newTickLower, newTickUpper)
  └── _collectYield()          // flush fees before closing
  └── _removeLiquidity(1e18)   // close 100% of current position
  └── positionTokenId = 0
  └── tickLower / tickUpper = new values
  └── _deployLiquidity(idle)   // reopen at new range
  └── emit Rebalanced
```

**Projected APY helper**

```
getProjectedAPY(recentYield, windowSeconds)
  → aprBPS = recentYield × 365d / windowSeconds × 10_000 / totalAssets()
```

Returns basis points. The caller supplies an externally observed `recentYield` window; the vault does not store a rolling average.

---

## Data Flow — Full Swap Cycle

```
1. Swapper calls PoolManager.swap()
2. PoolManager calls DynamicFeeHook.beforeSwap()
   → fee computed, stored in transient storage
3. Swap executes inside PoolManager
4. PoolManager calls DynamicFeeHook.afterSwap()
   → fee pulled from pool via poolManager.take()
   → feeDistributor.distribute(currency, fee) called
5. FeeDistributor splits fee:
   → 20% transferred to treasury
   → 80% donated back to pool (LP fee growth)
6. LP fee growth accumulates in pool state
7. LiquidityVault._collectYield() (on withdraw or explicit call)
   → harvests accumulated LP fees via PositionManager
   → totalYieldCollected incremented
   → share price appreciates for all depositors
```

---

## Security Properties

| Property | Mechanism |
|---|---|
| Hook-only fee distribution | `require(msg.sender == hook)` in `FeeDistributor.distribute()` |
| Two-step ownership | `Ownable2Step` on all three non-base contracts |
| Reentrancy | `ReentrancyGuard` on `FeeDistributor` and `LiquidityVault` |
| Emergency pause | `Pausable` on `LiquidityVault`; `pause()`/`unpause()` owner-only; blocks deposit, withdraw, redeem |
| Callback caller verification | `onlyPoolManager` modifier in `BaseHook` |
| Slippage on liquidity removal | 0.5 % minimum amount floor via `LiquidityAmounts.getAmountsForLiquidity` |
| Transient fee storage | EIP-1153 `TSTORE/TLOAD` — fee data never persists across transactions |
| Configurable fee cap | `maxFeePerSwap` prevents single-swap fee griefing |
| Minimum deposit | `MIN_DEPOSIT = 1e6` (1 USDC) guards against dust-share inflation |
| TVL cap | `maxTVL` (owner-set) — deposits revert with `TVL_CAP` when exceeded |
| Rescue guard | `rescueIdle(token)` reverts if `token == asset()` — owner cannot drain the vault's own asset |
| Anti-sandwich (volatility) | `lastSwapBlock` — reference price updates only once per block, blocking same-block multiplier suppression |
| Other-token sentinel guard | `currency1YieldCollected` tracking skips zero-code addresses to prevent precompile calls |

---

## Dependencies

| Library | Source | Purpose |
|---|---|---|
| `v4-core` | Uniswap | `PoolManager`, `PoolKey`, `TickMath`, `StateLibrary`, `BalanceDelta`, `Currency` |
| `v4-periphery` | Uniswap | `IPositionManager`, `Actions` |
| `v4-core/test/utils` | Uniswap (test lib) | `LiquidityAmounts` (superset — includes `getAmountsForLiquidity`) |
| OpenZeppelin v5 | OZ | `ERC4626`, `Ownable2Step`, `ReentrancyGuard`, `Pausable`, `Math` |

---

## Deployment

`script/Deploy.s.sol` is a Foundry broadcast script that:

1. Reads required env vars: `POOL_MANAGER`, `POS_MANAGER`, `TOKEN0`, `TOKEN1`, `TREASURY`.
2. Reads optional env vars: `PERFORMANCE_FEE_BPS` (default 500), `MAX_TVL` (default 0), `MAX_FEE_BPS` (default 50), `POOL_FEE` (default 100), `TICK_SPACING` (default 1), `SQRT_PRICE_X96` (default 1:1).
3. Deploys `FeeDistributor`, then `LiquidityVault`, then mines a CREATE2 salt for `DynamicFeeHook` so its address encodes the required hook permission bits.
4. Wires the circular dependency (`vault.setHook`, `distributor.setHook`, etc.).
5. Initialises the pool and registers the `PoolKey` on both the hook and vault.

Run with:
```bash
forge script script/Deploy.s.sol --broadcast --rpc-url $RPC_URL
```
| OpenZeppelin v5.6.1 | OZ | `ERC4626`, `Ownable2Step`, `ReentrancyGuard`, `Math` |

---

## Test Architecture

| Suite | File | Coverage |
|---|---|---|
| Unit — Hook | `test/DynamicFeeHook.t.sol` | Fee calc, volatility multiplier, cap, transient storage, routing |
| Unit — Distributor | `test/FeeDistributor.t.sol` | 20/80 split, access control, stats accumulation |
| Unit — Vault | `test/LiquidityVault.t.sol` | ERC-4626 mechanics, share price, yield, rebalance, APY math, Ownable2Step |
| Integration | `test/integration/` | Real v4-core `PoolManager`, multi-swap fee accumulation, donate flow |

Mocks:

- `MockPoolManager` — stubs `take`, `donate`, `sync`, `settle`, `initialize`, `extsload` (returns `sqrtPriceX96 = 1`).
- `MockPositionManager` — stubs `nextTokenId` and `modifyLiquidities`; supports `queueYield()` to simulate fee collection without a live pool.
- `MockERC20` — mintable ERC-20 for test asset.
