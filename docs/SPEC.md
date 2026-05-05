# The Pool V2.1 — Protocol Specification

**Status**: production, Arbitrum One.
**Audience**: auditors, integrators, sophisticated LPs.
**Source of truth**: contracts in `src/`. Where this document and the
contracts disagree, the contracts win — please file an issue.

This spec is the complement to [`docs/ARCHITECTURE.md`](ARCHITECTURE.md). The
architecture document is descriptive; this one is prescriptive: subsystem
boundaries, state machines, equations, and invariants.

## 1. Subsystem boundaries

The protocol is three layers, deliberately isolated:

| Layer | Contracts | Responsibility | Trust boundary |
|---|---|---|---|
| **Accounting** | `LiquidityVaultV2` (ERC-4626) | Share ↔ asset valuation. Single source of NAV truth. | Trustless. Owner cannot mint/burn shares directly. |
| **Execution** | `DynamicFeeHookV2`, `FeeDistributor`, `SwapRouter02ZapAdapter` | Hooked-swap fee capture, reserve fills, fee splitting, donation, zap. | Hook + distributor immutable. Adapter is narrow (`exactInputSingle` only). |
| **Incentive** | `BootstrapRewards` | Optional capped, time-bounded early-depositor program. | Cannot affect ERC-4626 share price. Failures are isolated by `try/catch`. |

The accounting layer never trusts the execution layer to push value into
share price. Value enters NAV only through:

1. ERC-20 balances physically held by the vault.
2. Realized LP-fee collections via `_collectYield()`.
3. Pulled reserve proceeds via `_pullReserveProceedsBoth()`.
4. Off-vault ERC-20 escrow / proceeds claims, marked-to-market by
   `totalAssets()` at clamped pool price.

## 2. NAV accounting (ERC-4626 layer)

### 2.1 Definitions

Let:

- $A_\text{idle}$ = vault balance of the deposit asset.
- $A_\text{pos}$ = asset-side amount implied by the v4 NFT at NAV reference
  price.
- $O_\text{pos}$ = other-token-side amount implied by the v4 NFT at NAV
  reference price.
- $O_\text{idle}$ = vault balance of the other token.
- $A_\text{pending}$, $O_\text{pending}$ = `proceedsOwed(vault, ·)` on the
  hook.
- $A_\text{escrow}$, $O_\text{escrow}$ = `escrowedReserve(vault, ·)` on the
  hook.
- $P_\text{spot}$ = pool spot price as `sqrtPriceX96`.
- $P_\text{clamp}$ = $P_\text{spot}$ clamped to
  $[\sqrt{P_\text{tickLower}}, \sqrt{P_\text{tickUpper}}]$.
- $Q(x, P)$ = quote of $x$ other-token units in asset units at price $P$.

### 2.2 Equation

$$
\text{totalAssets}() = A_\text{idle} + A_\text{pending} + A_\text{escrow}
+ A_\text{pos} + Q(O_\text{pos},\, P_\text{spot}) + Q(O_\text{idle} + O_\text{pending} + O_\text{escrow},\, P_\text{clamp})
$$

Live LP amounts use $P_\text{spot}$. Idle / pending / escrow other-token
balances use $P_\text{clamp}$. This pins out-of-range inventory to the
range edge so it cannot be over- or under-valued by spot drift.

**Uncollected LP fees are NOT in `totalAssets()`.** Uniswap v4 fee growth
on a position is realized only when `IPositionManager.collect` runs.
Until then, those fees are economically owed to the position but live
outside `totalAssets()`. Share price advances *step-wise* on every flush.

### 2.3 Flush points

`_collectYield()` is the only path that imports realized v4 LP fees into
NAV. It is called from:

| Caller | Path |
|---|---|
| Anyone (permissionless) | `collectYield()` |
| Depositor | `deposit / mint / depositWithZap` (implicit, before share math) |
| Redeemer | `withdraw / redeem / withdrawWithZap / redeemWithZap` (implicit) |
| Owner | `rebalance` (implicit, before recalculating ticks) |

Reserve proceeds are flushed into idle balances by
`_pullReserveProceedsBoth()` on the same paths.

### 2.4 Share-price model

There is one accounting truth: share price = `convertToAssets(1e18)`. The
contract does **not** track per-user reward balances. All depositor
attribution is share-based; transfer of shares transfers all unrealized
NAV proportionally.

Two complementary mechanisms:

- **Continuous (mark-to-market):** `totalAssets()` reprices the v4
  position, idle other-token, escrow, and pending proceeds at every
  read. Spot moves change share price between flushes only via the
  in-range LP value $Q(O_\text{pos}, P_\text{spot}) + A_\text{pos}$.
- **Step-wise (flush):** `_collectYield()` and
  `_pullReserveProceedsBoth()` migrate value from off-NAV (uncollected
  v4 fees, hook-held proceeds) into in-NAV idle balances. Share price
  jumps at flush; size of jump = realized fees + claimed proceeds.

A pure ERC-4626 reading is a lower bound on lifetime depositor
entitlement. Permissionless `collectYield()` is the user's escape hatch:
they can force a flush before any deposit/withdraw to lock in unrealized
LP fees into the share price they trade against.

## 3. Hook execution (Execution layer)

### 3.1 Fee path — equations

Let $\Delta_\text{out}$ be the AMM-routed unspecified-side delta of the
post-reserve swap (after any reserve absorption). With `HOOK_FEE_BPS =
25`, `VOLATILITY_FEE_MULTIPLIER = 150`, `maxFeeBps` ≤ 1000:

$$
f_\text{base} = \frac{\Delta_\text{out} \cdot \text{HOOK\_FEE\_BPS}}{10000}
$$

$$
f_\text{vol} = \begin{cases}
f_\text{base} \cdot \frac{\text{VOLATILITY\_FEE\_MULTIPLIER}}{100} & \text{if }|\Delta P / P_\text{ref}| \ge \frac{\text{VOLATILITY\_THRESHOLD\_BPS}}{10000} \\
f_\text{base} & \text{otherwise}
\end{cases}
$$

$$
f_\text{cap} = \frac{\Delta_\text{out} \cdot \text{maxFeeBps}}{10000}
$$

$$
f_\text{charged} = \min(f_\text{vol},\; f_\text{cap})
$$

The hook calls `poolManager.take(currency, distributor, f_charged)` and
returns `f_charged` as `afterSwapReturnDelta`.

### 3.2 Fee distribution

Default `treasuryShare = 20`, hard max `MAX_TREASURY_SHARE = 50`.

$$
f_\text{treasury} = \frac{f_\text{charged} \cdot \text{treasuryShare}}{100}, \quad f_\text{LP} = f_\text{charged} - f_\text{treasury}
$$

$f_\text{treasury}$ is `transfer`d to `treasury`. $f_\text{LP}$ is donated
back via `poolManager.donate(poolKey, ...)`. **Donations attach to
liquidity active at the donation tick at the moment of the donation** —
they are not retroactive and are not held in escrow. From v4
PoolManager's perspective this is a one-tick fee-growth credit.

### 3.3 LP share — temporal aggregation

Donated fees are distributed by Uniswap v4's standard fee-growth-per-tick
accounting. For an LP whose position spans the donation tick and whose
liquidity at donation time is $L_i$:

$$
\text{vault claim}_i = f_\text{LP} \cdot \frac{L_\text{vault}^{(t_d)}}{\sum_j L_j^{(t_d)}}
$$

evaluated at the donation block $t_d$. This is **liquidity-time-weighted
in the standard v4 sense**: an LP that joins the same range *after* the
donation block does not retroactively dilute the donation. They only
share future donations from their join block onward.

The vault's depositor-level share of any single donation is therefore:

$$
\text{depositor share} = \frac{L_\text{vault}^{(t_d)}}{\sum_j L_j^{(t_d)}} \cdot \frac{1}{\text{vault.totalSupply}}
$$

per share. Composability with external in-range LPs is a *first-class
risk*: the vault has no privileged donation channel.

> **Today-state vs invariant.** As of the deployment block, vault
> liquidity is the only material in-range LP on the WETH/USDC pool with
> this hook. That is a market state, not an invariant. The pool is
> permissionless; any third party can mint a Uniswap v4 position that
> overlaps the vault's tick band and dilute future donations
> proportional to their $L_j$. The vault has no power to block this.

### 3.4 Reserve-fill execution — invariants

Let $P_\text{vault}$ = the keeper-posted offer quote (`sqrtPriceX96`),
$P_\text{spot}$ = the live `sqrtPriceX96` from `StateLibrary.getSlot0`,
both expressed as $\text{token1}/\text{token0}$.

For mode `PRICE_IMPROVEMENT`, side `vault sells token1`:

$$
\text{fill allowed} \iff P_\text{spot} \le P_\text{vault}
$$

For mode `PRICE_IMPROVEMENT`, side `vault sells token0`:

$$
\text{fill allowed} \iff P_\text{spot} \ge P_\text{vault}
$$

For mode `VAULT_SPREAD` the inequalities flip: the vault only fills when
its quote captures positive spread vs spot.

In both cases:

- Fills are exact-input only.
- Direction of swap must match the offer side.
- `block.timestamp <= offer.expiry`.
- Inventory remaining > 0.
- Returned `BeforeSwapDelta` must fit in `int128`.

If any check fails, the hook short-circuits to the AMM leg and the
reserve offer is untouched. There is no partial bypass and no
keeper-controlled price slippage knob: the on-chain inequality is the
sole gate.

The `ReserveOfferStale` event fires when a direction-matched fill
attempt fails by more than `STALE_DRIFT_BPS = 50` bps of drift, so
keepers can re-quote without inspecting per-block reverts.

## 4. State machines

### 4.1 Vault range state

```
            deposit / mint
              |
   UNCONFIGURED ──setPoolKey──> CONFIGURED ─► ACTIVE_INRANGE
                                  │             │  ▲
                                  │             │  │ pool spot re-enters band
                                  │             ▼  │
                                  │           ACTIVE_OUTOFRANGE
                                  │             │
                                  ├─pause──> PAUSED ◄──unpause───┐
                                  │             │                │
                                  ▼             ▼                │
                              (any)         (any) ────unpause────┘
```

`vaultStatus(vault)` exposed by `VaultLens` reports
`{UNCONFIGURED, PAUSED, IN_RANGE, OUT_OF_RANGE}`. Note that **IN_RANGE
means *eligible* to earn**, not *currently earning*. Actual fee accrual
requires:

$$
\text{accruing} \iff \text{IN\_RANGE} \;\wedge\; \exists\, \text{hooked swap with } \Delta_\text{out} > 0 \text{ in current block}
$$

Idle in-range periods earn zero. Concentrated-liquidity is a
*conditional* flow asset.

### 4.2 Reserve offer state

```
   IDLE ──offerReserveToHookWithMode──► ACTIVE
     ▲                                    │
     │                                    │ swap matches gate
     │                                    ▼
     │                                 ACTIVE (inventory ↓, proceeds ↑)
     │                                    │
     │     cancelReserveOffer ◄───────────┤
     │                                    │ inventory == 0
     │                                    ▼
     │                                 EMPTY ──claim───► IDLE
     │                                    │
     │     block.timestamp > expiry       │
     ◄────EXPIRED──────────────────────────┘
```

`rebalanceOfferWithMode` is atomic `cancel → claim both sides → post`.

### 4.3 Bootstrap epoch state

```
   UNCONFIGURED ──setPayout──► PRE_PROGRAM
                                  │
                            block.timestamp >= start
                                  ▼
                              EPOCH_OPEN ──pullInflow──► EPOCH_OPEN (pool ↑)
                                  │
                            block.timestamp >= epochEnd
                                  ▼
                              EPOCH_FINALIZED ──claim(epoch)──► CLAIMED
                                  │
                            block.timestamp >= claimDeadline
                                  ▼
                              EPOCH_CLOSED ──sweepUnclaimed──► CLOSED
```

Funded epoch balance is separate from the cap. Pool can be $0$ even
when the cap is non-zero. The cap is a ceiling; it is not a commitment.

## 5. Invariants

The following must hold at every externally observable state:

### 5.1 Accounting

- **I-A1** `totalSupply == 0 ⇒ totalAssets() can be 0 or non-zero (donated
  dust); the next deposit follows ERC-4626 virtual-shares math`.
- **I-A2** `convertToAssets(totalSupply()) ≤ totalAssets()` (no minting
  beyond NAV).
- **I-A3** Share price across a single block is monotonic non-decreasing
  in absence of (a) pool spot moving against the LP position, (b)
  successful sandwich resistance failure, (c) impermanent loss
  realization through `withdraw`. In particular, `_collectYield()` and
  `_pullReserveProceedsBoth()` only ever *increase* `totalAssets()`.
- **I-A4** **NAV deviation guard.**
  $|P_\text{spot} - P_\text{ref}| / P_\text{ref} \le
  \text{maxNavDeviationBps} / 10000$ on every share-mint and share-burn
  path; otherwise revert `NAV_PRICE_DEVIATION()`.

### 5.2 Hook fee routing

- **I-H1** $f_\text{charged} \le \frac{\Delta_\text{out} \cdot
  \text{maxFeeBps}}{10000} \le \frac{\Delta_\text{out} \cdot 1000}{10000}$.
- **I-H2** Every successful `afterSwap` either calls `take` with exactly
  $f_\text{charged}$ and returns it as `afterSwapReturnDelta`, or
  reverts; no fee is silently swallowed.
- **I-H3** Conservation: $f_\text{charged} = f_\text{treasury} +
  f_\text{LP}$ within `FeeDistributor.distribute()`. Reentry attempts
  hit `ReentrancyGuard`.
- **I-H4** Hook callbacks revert on `msg.sender != poolManager` via
  `BaseHook.onlyPoolManager`.

### 5.3 Reserve

- **I-R1** $\sum_t \text{ReserveFilled}(t).\text{amountIn} \le
  \text{totalReserveSold}$ and equality holds modulo unclaimed proceeds.
- **I-R2** `escrowedReserve[vault][c] >= 0` and only decreases on fill or
  cancel. Increases only on `offerReserveToHookWithMode`.
- **I-R3** **One vault per pool.** `registerVault[poolId]` is one-shot.
  After registration, only that address satisfies the `onlyVault`
  modifier on offer mutations and proceeds claims.
- **I-R4** Reserve-fill price gate (Section 3.4) is the only reserve
  execution authority. No keeper key, no admin key, can override it.
- **I-R5** `BeforeSwapDelta` returned by a fill fits in `int128` on each
  side; otherwise the hook reverts the reserve path and falls through to
  AMM-only.

### 5.4 Custody

- **I-C1** Vault's `owner()` MUST be `VaultOwnerController`. Direct
  vault `transferOwnership` calls are still possible but disabled by
  policy; controller-mode keeper writes assume this binding.
- **I-C2** Hot keeper EOA can call only the four typed reserve selectors
  on the controller. The Safe-only `executeVaultOwnerCall(bytes)` escape
  hatch *rejects* those four selectors so reserve activity always emits
  `ReserveKeeperCallExecuted`.
- **I-C3** Hook, distributor, vault, controller, bootstrap, and zap
  adapter contracts are non-upgradeable. Migration requires redeployment
  and a new pool registration.

### 5.5 Bootstrap

- **I-B1** `BootstrapRewards.poke()` failures cannot block share
  movement. The vault wraps every poke in `try/catch` and emits
  `BootstrapPokeFailed` on revert.
- **I-B2** Epoch payouts are bounded by funded balance, not by cap.
  Sum of `claim(epoch)` outflows ≤ `epoch.funded`.
- **I-B3** Cap is a ceiling, not a commitment. Funded balance can be
  zero indefinitely.

## 6. Risk surface (formal)

| Risk | Bounded by | Residual |
|---|---|---|
| Impermanent loss vs USDC basis | None at protocol level. Range choice and rebalance cadence shift but cannot eliminate. | Borne entirely by depositors. |
| Sandwich on share mint/burn | NAV deviation guard (`maxNavDeviationBps`). | An attacker willing to move spot < deviation can still extract $\le$ deviation per round trip. |
| LP donation dilution | Liquidity-time-weighted accounting at donation block. | Any third-party in-range LP dilutes future donations $L_\text{vault}/\sum L_j$. |
| Reserve adverse selection | `PRICE_IMPROVEMENT` / `VAULT_SPREAD` gate at on-chain spot. | Quote is keeper-posted; stale quotes can fail the gate but cannot fill at a worse-than-spot price for the vault. |
| Range stagnation | Owner `rebalance()`. | Depositors carry timing risk for owner reaction. |
| Fee distribution failure | `failedDistribution` tally + `retryDistribute` / `sweepUndistributed`. | Non-blocking on swaps. Operator must intervene for treasury share to flow. |
| Bootstrap funding shortfall | Cap is a ceiling; pool may be empty. | No pre-funding, no commitment. Disclose explicitly. |
| Custody compromise | 2-of-N (Safe) on controller; hot key scoped to reserve selectors. | Compromise of Safe = compromise of vault. |

## 7. Open items

- **Hook fee counter currency-mixing.** `totalFeesRouted` aggregates
  output-side deltas across both pool currencies into a single
  `uint256`. Off-chain consumers cannot interpret it as a single
  currency-denominated total. A future hook revision should expose
  `feesRoutedByCurrency[Currency] -> uint256`. Tracked off-spec.
- **Reserve quote source.** Posted by an allowlisted keeper EOA. The
  quote is constrained by the on-chain price-improvement gate; it is
  not an oracle commitment. Integrators that require oracle anchoring
  should not treat reserve fills as reference prices.

---

This document covers V2.1 only. V1 (`src/archive-v1/`) is not in scope.
