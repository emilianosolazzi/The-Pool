# The Pool

**A Uniswap v4 hook protocol that routes swap-level hook fees into LP yield.**

The Pool attaches a programmable fee layer to any Uniswap v4 concentrated-liquidity pool. Swap fees are captured on-chain, split between the protocol treasury and LP fee growth, and credited to share price in an ERC-4626 vault — so liquidity providers earn more without changing their workflow.

> Fee-only LP yield on Uniswap v4. No token, no emissions, no lockups. 25 bps dynamic hook fee on swaps, scaled 1.5× in volatile blocks; by default 80% is donated directly back to the pool on the same transaction (treasury share is owner-adjustable, hard-capped at 50%). Share price appreciates as fees accrue — no claim flow, no staking. Anyone can call `collectYield()`, and redeployment occurs through `deposit()` or owner `rebalance()` paths. Owner-adjustable tick range with zero accounting impact on depositors.

During the bootstrap program, `FeeDistributor.treasury` is set to the `BootstrapRewards` contract, which routes a portion of the treasury share back to early LPs as epoch bonuses — so effective LP share during the program window is higher than the steady-state 80%.

---

## Architecture

```
Swapper ──► Uniswap v4 PoolManager
                   │  beforeSwap / afterSwap
                   ▼
           DynamicFeeHookV2
                   │  distribute()
                   ▼
           FeeDistributor
            ├─ treasuryShare ──► Treasury        (default 20%, owner-adjustable, capped at 50%)
            └─ remainder ──► poolManager.donate()  (default 80%; accrues to all in-range LPs)
                              │  collectYield / withdraw / rebalance
                              ▼
                       LiquidityVaultV2  (ERC-4626)
                              │  modifyLiquidities()
                              ▼
                    v4-periphery PositionManager
```

Each swap attempts to apply a 25 BPS hook fee. During periods of elevated volatility — defined as a ≥ 1% price move since the last block — the fee scales to **1.5×**. The total fee is routed through `FeeDistributor`: by default 20% goes to the treasury and 80% is donated back to the pool via `poolManager.donate()`, flowing directly into LP fee growth. The treasury share is owner-adjustable via `setTreasuryShare`, hard-capped at 50% (LP share floor 50%). Fee yield collected by the vault accrues to share price; harvesting is permissionless via `collectYield()`, and redeployment into the active tick range occurs on `deposit` and owner `rebalance` paths.

---

## Contracts

| Contract | Description |
|---|---|
| `src/BaseHook.sol` | Abstract base — `onlyPoolManager` callback guard, permission-bit validation at deployment |
| `src/DynamicFeeHookV2.sol` | Fee computation, volatility multiplier, reserve-sale fills, failed-distribution accounting, fee routing |
| `src/FeeDistributor.sol` | Default 20 / 80 treasury-to-LP fee split via `poolManager.donate()`; treasury share owner-adjustable, hard-capped at 50% |
| `src/LiquidityVaultV2.sol` | ERC-4626 vault — deposits, withdrawals, rebalances, reserve-offer glue, NAV deviation guard |
| `src/BootstrapRewards.sol` | Early-depositor bonus program — epoch share-second accrual, lazy poke, pull-style claims |
| `src/SwapRouter02ZapAdapter.sol` | Narrow adapter from `LiquidityVaultV2` to Uniswap V3 SwapRouter02 `exactInputSingle` for zap deposits/withdrawals |

For a full description of state machines, data flows, and invariants, see [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

For operator procedures, trust assumptions, and failure-mode response, see [`docs/HOOK-RISK-RUNBOOK.md`](docs/HOOK-RISK-RUNBOOK.md).

For detailed mathematical examples of yield generation and APY calculations, see [`docs/VALUE-EXAMPLES.md`](docs/VALUE-EXAMPLES.md).

For an investor-facing volume thesis and scenario-based ROI model, see [`docs/INVESTOR-README.md`](docs/INVESTOR-README.md).

For code examples and integration snippets, see [`docs/CODE-EXAMPLES.md`](docs/CODE-EXAMPLES.md).

---

## Features

**For liquidity providers**
- **Fee yield credited to share price** — swap fees accrue to `totalAssets()` on every `_collectYield()`; no manual claim required
- **Permissionless `collectYield()`** — any caller (keeper, depositor, frontend) can harvest fees; redeployment into the active range is handled by `deposit()` and owner `rebalance()` paths; out-of-range conditions early-return silently
- **Proportional accounting** — share price appreciates uniformly across all depositors; early depositors retain their yield advantage
- **Tick rebalancing** — the owner can shift the concentrated-liquidity range without disrupting depositor balances or share price

**For the protocol**
- **Dynamic fee capture** — 25 BPS base fee, scaling 1.5× in volatile conditions; revenue scales with market activity
- **Performance fee** — owner-configurable treasury cut on harvested yield (0 – 20%, deploy default 4%)
- **TVL cap** — optional ceiling on total deposits to manage controlled rollout

**Security**
- **Anti-sandwich protection** — the volatility reference price updates at most once per block, blocking same-block multiplier suppression attacks
- **Emergency pause** — owner can halt all deposits, withdrawals, and redeems instantly
- **No vault-asset rescue path** — V2 removed `rescueIdle`; `rescueNative` is only for forced native-ETH dust
- **Zero-address guards** — treasury, hook, and distributor setters all reject `address(0)`
- **`SafeERC20`** — all token transfers use OpenZeppelin `safeTransfer`, handling non-standard ERC20s

---

## Getting Started

### Prerequisites

- [Foundry](https://book.getfoundry.sh/) (`forge`, `cast`)
- Solidity `>=0.8.24 <0.9.0`

### Install

```bash
git clone https://github.com/emilianosolazzi/The-Pool
cd The-Pool
forge install
```

### Test

```bash
# Unit and integration tests
forge test --no-match-contract "Invariant"

# Full suite including stateful invariant fuzzing
forge test
```

**228/228 tests passing** (V2.2 hardening baseline: deterministic suites plus 5 handler-driven fuzz invariants, default invariant profile: 256 runs × depth 15).

### Deploy

Copy `.env.example` to `.env` and populate the required variables:

```bash
ARBITRUM_RPC_URL=
PRIVATE_KEY=

# Required
POOL_MANAGER=        # Uniswap v4 PoolManager address on target network
POS_MANAGER=         # Uniswap v4 PositionManager address
TOKEN0=              # Lower-address token of the pair
TOKEN1=              # Higher-address token of the pair
TREASURY=            # Address that receives the treasury share (default 20% of hook fees)

# Optional — pick the vault's deposit asset (defaults to TOKEN0)
ASSET_TOKEN=         # Must equal TOKEN0 or TOKEN1
```

#### Reference deployment — USDC / WETH on Arbitrum One

The vault is **single-sided out-of-range** by design: it holds one asset and earns fees while waiting to convert into the other across a configured tick band. For a USDC-deposit vault on the Arbitrum USDC / WETH pair, WETH (`0x82aF…`) sorts below USDC (`0xaf88…`), so `TOKEN0=WETH`, `TOKEN1=USDC`, and `ASSET_TOKEN=TOKEN1`. **Pool: 0.05% fee tier (`POOL_FEE=500`), `TICK_SPACING=60`.** Default ticks in [`LiquidityVaultV2`](src/LiquidityVaultV2.sol) (`tickLower = -199020`, `tickUpper = -198840`, both multiples of 60) target a narrow band centred on the current WETH/USDC spot price: the vault deploys both sides while spot is inside the band and holds idle inventory in either currency when spot drifts out. The owner can `rebalance(newTickLower, newTickUpper)` any time to a new pair of tick-spacing-aligned ticks. A ready-to-edit preset lives in [`.env.example`](.env.example).

Optional parameters with their script defaults (the live Arbitrum One deployment overrides `POOL_FEE` / `TICK_SPACING` via `.env.example` to match the 0.05% USDC/WETH pool):

```bash
PERFORMANCE_FEE_BPS=400    # Vault yield cut sent to treasury (0–2000 BPS)
MAX_TVL=0                  # Deposit ceiling in asset-token units; 0 = unlimited
MAX_FEE_BPS=50             # Hook fee ceiling in BPS (hard cap, max 1000)
POOL_FEE=500               # Uniswap v4 pool fee tier (0.05%; reference deployment)
TICK_SPACING=60            # Pool tick spacing (matches the live Arbitrum One USDC/WETH pool)
SQRT_PRICE_X96=            # Initial pool price; omit to default to 1:1
```

Broadcast the deployment:

```bash
forge script script/DeployHookV2AndVault.s.sol --broadcast --rpc-url $ARBITRUM_RPC_URL
```

The deploy script mines a valid hook address (CREATE2 with permission bits), deploys all four contracts in dependency order, wires the circular references, initialises the pool, and registers the pool key on both the hook and the vault. `BootstrapRewards` is deployed separately via [`script/DeployBootstrap.s.sol`](script/DeployBootstrap.s.sol) once the vault and distributor addresses are known.

**Target network: Arbitrum One.**

### Live Arbitrum One deployment

> **V2.2 redeploy pending.** The addresses below are the original V1 deployment of the protocol. They are listed here for historical traceability of the on-chain artifacts, but they do **not** match the current `src/` source: the live hook predates the V2 distributor-soft-fail and reserve-offer hardening described above. A fresh V2.2 deploy of `FeeDistributor`, `DynamicFeeHookV2`, `LiquidityVaultV2`, `SwapRouter02ZapAdapter`, and `BootstrapRewards` will replace these addresses; this section will be updated once the redeploy ships.
>
> Always verify current contract parameters on-chain before interacting; tick ranges, NAV reference, TVL cap, treasury, and fee settings may change through owner-controlled operations.

| Component | Address (V1, pending replacement) |
|---|---|
| FeeDistributor | `0x9e3aAb5DdBF536c087319431afCAf2F1160942e1` |
| LiquidityVault | `0x02D5a1340D378695D50FF7dE0F5778018952c5EA` |
| DynamicFeeHook | `0x453CFf45DAC5116f8D49f7cfE6AEB56107a780c4` |
| BootstrapRewards | `0x029C2FEeB98050295C108E370fa74081ed58F978` |

> The tick range above documents the **source defaults** in [`LiquidityVaultV2`](src/LiquidityVaultV2.sol). The live vault has been operationally `rebalance()`d since deployment and may sit at a different tick-spacing-aligned range. Read `tickLower` / `tickUpper` from the deployed contract for the current live corridor.

Deploy txs (V1):
- Deploy FeeDistributor: `0xa7aafdf7635948d964270ad47f68924d8b5baaeca24f085627c057564d70fb24`
- Deploy LiquidityVaultV2: `0x36c5d0f0d36cdf519cf5acc42b6d77d960967a7c2cdd0f660d51b71c71ed96aa`
- Deploy DynamicFeeHookV2: `0xe38566b012f57c6ca50708db08fbe730895bc17e3d8478dc8f934a16b0f1ca99`
- Deploy BootstrapRewards: `0xf4fb48b675c92bafb134609efedfc78b09d5370fe266db55c671aacb20d07200`
- Wire `FeeDistributor.treasury` to BootstrapRewards: `0xa2334a4c6883cb9ffeaf5dc8cd579d5d04ac42eb2a5941b1d1a60f05e76e1127`
- Initialize PoolManager pool: `0xee5a11b901b6df18c03f6b9a1064682cfea0ec0e7885aee2a223840bd5addfc1`
- Register pool key on FeeDistributor: `0xae8589536266e577d10119b9bce898ae2145eba78aec8f488644d9291189250b`
- Register pool key on LiquidityVaultV2: `0xac7bab8d392d558bad55f1bd7ff64bd8fca9acb8eeceb7d11591d771725f2165`

---

## Security

### Internal Audit: Complete

All critical paths have been reviewed with emphasis on correctness, arithmetic precision, and invariant preservation. Remediation is complete.

**Audit scope included:**

- Fee calculation correctness across swap size boundary conditions
- `FeeDistributor` 20 / 80 split with exact rounding validation
- `poolManager.donate()` accounting integrity end-to-end
- ERC-4626 share price invariance across deposit, withdraw, redeem, and yield cycles
- Reentrancy analysis on all state-mutating entry points
- EIP-1153 transient storage slot isolation
- Hook permission-flag validation at deployment
- `setPoolKey` pool membership enforcement (`ASSET_NOT_IN_POOL` guard)
- Native-ETH rejection (`receive`/`fallback`) plus owner-only `rescueNative` for forced dust
- Same-block sandwich vector on the volatility multiplier (`lastSwapBlock`)
- Emergency pause coverage across all user-facing entry points
- Zero-address rejection on all privileged setters

**Test suite:**

- Current V2.2 baseline: **228/228 passing**
- Stateful invariant fuzz suites: **5 tests** at **256 runs × depth 15**

### Automated Audit: Complete

Pre-audited with **TSI Audit Scanner** — an open-source temporal-state-inconsistency static analysis tool — with V2.2 hardening re-test completed **2026-04-27**. Reported findings were remediated and re-tested; the published verdict is **PASSED**.

Full report: [audits/TSI-Audit-Scanner_2026-04-25.md](audits/TSI-Audit-Scanner_2026-04-25.md).

Operational companion: [docs/HOOK-RISK-RUNBOOK.md](docs/HOOK-RISK-RUNBOOK.md).

> **Disclosure:** TSI Audit Scanner is an in-house static analysis tool, not an arm's-length third-party firm. It complements but does not replace human review.

A first review by an **independent third-party human auditor** is scheduled at \$100K TVL. The system is independently built and self-funded. Security spend is tied to capital at risk — not optics.

### Verification

- All source code is public.
- Tests are reproducible with `forge test`.
- Core arithmetic is isolated, unit-tested, and covered by deterministic and handler-driven fuzz invariant suites.
- Privileged roles, trust assumptions, and operator procedures are documented in [`docs/HOOK-RISK-RUNBOOK.md`](docs/HOOK-RISK-RUNBOOK.md).

The system has explicit owner/operator assumptions. These are documented rather than hidden.

