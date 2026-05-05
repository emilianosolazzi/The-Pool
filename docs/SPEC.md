# The-Pool-Adaptive-Reserve-Hook V2.1 — Protocol Specification

**Status**: production, Arbitrum One.
**Audience**: auditors, integrators, sophisticated LPs.
**Source of truth**: contracts in `src/`. Where this document and the
contracts disagree, the contracts win — please file an issue.

This spec is the complement to [`docs/ARCHITECTURE.md`](ARCHITECTURE.md). The
architecture document is descriptive; this one is prescriptive: subsystem
boundaries, state machines, equations, and invariants.

## 0. Reading guide — separation of layers

Claims in this document live in exactly one of three layers. Mixing
them is the most common reading error.

| Layer | What is true here | Where to verify |
|---|---|---|
| **(P) Uniswap v4 protocol** | Invariants of v4 itself: `donate()`, `feeGrowthInside`, per-tick `liquidityNet`, active-liquidity scalar $L$. | `lib/v4-core` |
| **(I) This implementation** | Choices made by *our* contracts: what `totalAssets()` includes, when `_collectYield()` runs, NAV deviation guard, reserve-fill gate. | `src/LiquidityVaultV2.sol`, `src/DynamicFeeHookV2.sol`, `src/FeeDistributor.sol` |
| **(N) Narrative / UI** | Plain-English restatements for product surfaces. Always informal. | `web/components/*` |

Every numbered claim below is tagged **(P)**, **(I)**, or **(N)**. A
claim's truth value should never be inherited across layers.

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

### 2.2 Equation **(I)**

$$
\text{totalAssets}() = A_\text{idle} + A_\text{pending} + A_\text{escrow}
+ A_\text{pos} + Q(O_\text{pos},\, P_\text{spot}) + Q(O_\text{idle} + O_\text{pending} + O_\text{escrow},\, P_\text{clamp})
$$

Live LP amounts use $P_\text{spot}$. Idle / pending / escrow other-token
balances use $P_\text{clamp}$. This pins out-of-range inventory to the
range edge so it cannot be over- or under-valued by spot drift.

**Implementation note (I): uncollected v4 fees are intentionally
excluded from `totalAssets()`.** This is a *choice* of this vault, not
a property of ERC-4626 or Uniswap v4. ERC-4626 leaves `totalAssets()`
implementation-defined; some vaults pre-include claimable fees
("continuous harvest"), others post-include only realized fees
("discrete harvest"). Our `LiquidityVaultV2.totalAssets()` (see
[`src/LiquidityVaultV2.sol`](../src/LiquidityVaultV2.sol)) values the v4
position by liquidity amount only; uncollected `feeGrowthInside`
growth is realized only when `IPositionManager.collect` is invoked
through `_collectYield()`. We chose discrete harvest because it keeps
`totalAssets()` evaluable without trusting an off-position view that
can be perturbed by flash-minted positions in the same block. Any
integer reader can re-compute NAV from public state without
impersonating v4's per-position view.

A different vault wrapping the same v4 hook could choose continuous
harvest and still satisfy ERC-4626; that is why this fact is **(I)**
rather than a global invariant.

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

Share price = `convertToAssets(1e18)` is the single accounting anchor;
the contract does **not** track per-user reward balances. All depositor
attribution is share-based; transferring shares transfers all unrealized
NAV proportionally.

#### 2.4.1 NAV decomposition (categorical)

For any block $b$:

$$
\text{NAV}(b) \;=\; \underbrace{\text{totalAssets}(b)}_{\text{realized}} \;+\; \underbrace{F^{(v4)}_\text{vault}(b)}_{\text{latent}}
$$

where $F^{(v4)}_\text{vault}(b)$ is the Uniswap v4 fee growth accrued
to the vault's NFT position id $\pi$ between its last
`IPositionManager.collect` and block $b$:

$$
F^{(v4)}_\text{vault}(b) \;=\; L_\pi \cdot \Big( f_g^{\,inside}(\tau_L, \tau_U, b) - f_g^{\,inside}(\tau_L, \tau_U, b_{\text{lastCollect}}) \Big)
$$

following v4's `feeGrowthInside` per-position bookkeeping.

**Classification — latent NAV is a deterministic receivable.** Once v4
fee growth has been credited to position $\pi$, the protocol
*guarantees* the vault can claim it via `IPositionManager.collect` (path
exposed permissionlessly through `collectYield()`). The amount is fixed
at each block; it is not execution-dependent in price. The only
remaining variables are:

- *gas* (bounded, paid by the caller of `collectYield`); and
- *timing of MTM* of the **other-token** portion of those fees once they
  hit the vault as idle balances — priced at $P_\text{clamp}$, not at
  arbitrary spot.

$F^{(v4)}_\text{vault}(b)$ is therefore an accounting asset, not a
probabilistic claim. We deliberately exclude it from `totalAssets()` to
keep the realized side tamper-evident (no off-chain oracle, no v4 view
that could be manipulated by a flash position), not because the claim
is uncertain.

#### 2.4.2 Temporal model **(I)** — RCLL step function

The step-function shape of share price is a consequence of the
discrete-harvest choice in §2.2. Other implementations of the same
strategy on a different vault could produce a continuous share price
signal; this is not a general property of ERC-4626 or v4 hooks.

Let $\mathcal{F}$ = set of flush blocks (any block where
`_collectYield()` or `_pullReserveProceedsBoth()` runs successfully).
Define the on-chain share price as:

$$
S(b) \;=\; \frac{\text{totalAssets}(b)}{\text{totalSupply}(b)}
$$

Then $S$ is **right-continuous, lower-limit (RCLL)** in $b$: continuous
in $P_\text{spot}$ between flushes (mark-to-market of realized NAV
only), with upward jumps of size

$$
\Delta S(b^*) \;=\; \frac{F^{(v4)}_\text{vault}(b^*) + \Delta\,\text{proceeds}(b^*)}{\text{totalSupply}(b^*)}, \quad b^* \in \mathcal{F}
$$

at each flush block $b^*$. Between flushes, $S$ is a **lower bound** on
the true depositor entitlement
$(\text{realized}+\text{latent})/\text{totalSupply}$. Any caller may
force $b^* = \text{block.number}$ by calling permissionless
`collectYield()`; the latency between latent accrual and realized
recognition is therefore bounded by the caller's gas, not by trust.

*UI implication **(N)**:* dashboards should treat the displayed share
price as the RCLL value, not as a smooth continuous signal. Headline
yield figures must be either (a) post-flush, or (b) explicitly labeled
"realized only — excludes uncollected LP fees."

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

### 3.3 LP reward function — single canonical form

`FeeDistributor` calls `poolManager.donate(poolKey, a0, a1, "")`. We
specify the resulting LP credit by collapsing snapshot, scope, and
time-emergence into one expression.

#### 3.3.1 Denominator semantics **(P)**

v4 maintains an **active liquidity scalar** $L(t)$ per pool: the running
sum of `liquidityNet` for all ticks crossed up to the current tick,
equivalently the net liquidity contributed by every position whose tick
range covers the active tick. When `donate()` is called, v4 credits the
donation against $L(t_d)$ and accrues each position's pro-rata share via
`feeGrowthInside`. We write the denominator either way:

$$
L(t_d) \;=\; \sum_{k \in \mathcal{S}(t_d)} L_k^{(t_d)}
$$

The two forms are mathematically equal; the scalar is the on-chain
ground truth (`Pool.State.liquidity` on this `PoolId`). The set
$\mathcal{S}(t_d)$ below is the *position-side* view of the same
quantity.

**Scope is strictly the canonical PoolKey:**

$$
\text{poolKey} := (\text{currency0}, \text{currency1}, \text{fee}, \text{tickSpacing}, \text{hooks})
$$

deployed at
[`DEPLOYED_ADDRESSES.md`](DEPLOYED_ADDRESSES.md), identified by its
`PoolId = keccak256(abi.encode(poolKey))`.

- **Included:** every position $j$ minted via
  `IPositionManager.modifyLiquidities` against this exact `poolKey`
  whose tick range covers the active tick at $t_d$.
- **Excluded:** positions on any other Uniswap v4 pool (different fee
  tier, tickSpacing, hooks address, or currency pair); all Uniswap v3
  positions; all external-AMM positions.

The denominator is therefore *active liquidity density at $\tau_{t_d}$
on this PoolId*, not a raw enumeration of LP positions and not a global
v4 sum.

#### 3.3.2 Temporal discretization **(P)**

The atomic unit of LP reward accounting is the **donation event**, one
per `FeeDistributor.distribute()` call (typically one per hooked swap).
Let $d \in \mathbb{N}$ index donation events globally on this `PoolId`,
and let $t_d$ = `block.number` at which donation $d$ is included.
Liquidity is sampled **at $t_d$**, not over a window: $L_j^{(t_d)}$ is
position $j$'s $L$ value as written into v4's pool state at the moment
`donate()` executes. Positions minted, increased, decreased, or burned
earlier in the same block are reflected; later transactions are not.
Multiple donations in the same block are distinct $d$'s with the same
$t_d$ but distinct intra-block sequencing.

#### 3.3.3 Reward function **(P)**

Define the snapshot in-range set

$$
\mathcal{S}(t_d) := \{\,j \;\mid\; j \text{ is on this PoolId} \,\wedge\, \text{tickLower}_j \le \tau_{t_d} < \text{tickUpper}_j\,\}
$$

For any position $i \in \mathcal{S}(t_d)$:

$$
\boxed{\;
\text{credit}_i \;=\; \sum_{d \,:\, i \in \mathcal{S}(t_d)} f_\text{LP}(d) \cdot \frac{L_i^{(t_d)}}{L(t_d)}
\;}
$$

This is the **only** LP reward function in the protocol — it is the
direct specialization of v4's `feeGrowthInside` accounting to the
donation case. Three properties:

1. **Per-event snapshot.** The inner ratio is block-instantaneous; no
   per-position duration accumulator exists in any contract.
2. **Event-weighted exposure (not count).** Yield is the sum of
   $L_i^{(t_d)} \cdot f_\text{LP}(d) / L(t_d)$ over donation events the
   position is in-range for. A single large $f_\text{LP}(d)$ can
   outweigh many small ones; "liquidity-time-weighting" colloquially
   means *time-integrated exposure to discrete donation events*, not a
   count of events.
3. **Forward-only dilution.** A position minted at $t > t_d$ has
   $L_i^{(t_d)} = 0$ and is absent from $\mathcal{S}(t_d)$ entirely; it
   can only enter the sum for donations $d'$ with $t_{d'} \ge t$.

> **Today-state vs invariant (N).** As of the deployment block, vault
> liquidity is the only material contributor to $L(\tau_\text{now})$ on
> this PoolId. That is a market state, not a protocol invariant. The
> pool is permissionless; any third party can mint a Uniswap v4
> position whose tick range covers the active tick and immediately
> contribute to $L$ for all future donations. The vault has no
> structural privilege over donation accrual.

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
`{UNCONFIGURED, PAUSED, IN_RANGE, OUT_OF_RANGE}`. **IN_RANGE means
*eligible* to earn**, not *currently earning*.

Fee accrual **(P)** is fully specified by membership in
$\mathcal{S}(t_d)$ from §3.3:

$$
\text{accruing}_\pi(W) \iff \exists\, d \;\text{s.t.}\; t_d \in W \,\wedge\, \pi \in \mathcal{S}(t_d) \,\wedge\, f_\text{LP}(d) > 0
$$

Three conjuncts: (i) a donation event must occur in window $W$, (ii)
the vault position $\pi$ must be a member of $\mathcal{S}$ at that
event (its tick range covers the active tick), and (iii) the LP-side
fee at that event is positive. v4 distributes the fee to the active
liquidity at that moment; whether an individual swap *crosses* the
band is irrelevant.

The popular phrasing "fees only accrue when spot is inside the range"
is a **(N)**-layer informal restatement of (ii) using the equivalence
between "active tick lies in $[\text{tickLower}, \text{tickUpper})$"
and "$P_\text{spot}$ lies in the range's price band." It is not a
separate condition; do not treat it as one.

Idle in-range periods earn zero — no $d$, no accrual.
Concentrated-liquidity is a *conditional* flow asset.

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
