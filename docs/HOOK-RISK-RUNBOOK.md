# Hook-Risk & Audit-Readiness Operator Runbook

**Status:** V2.2 hardening re-test @ commit `64b48aa`, 2026-04-27.
**Companion documents:**
[`audits/TSI-Audit-Scanner_2026-04-25.md`](../audits/TSI-Audit-Scanner_2026-04-25.md),
[`docs/ARCHITECTURE.md`](ARCHITECTURE.md),
[`lib/VERSIONS.md`](../lib/VERSIONS.md).

This runbook is a single-page summary of:

1. The trust model and the attack surface introduced by the V2 reserve-sale
   state machine.
2. The auditor's mental map of which contract owns which invariant.
3. The owner / operator response procedures for the four failure modes the
   V2.2 hardening pass added explicit on-chain primitives for: failed
   distribution, native-ETH dust, NAV anchor drift, and pause / rotate.

It is **not** a replacement for the audit report. The audit report is the
authoritative record of findings; this runbook is the operational
companion.

---

## 1. Trust model

### Contracts in scope

| Contract | Address class | Trust |
|----------|---------------|-------|
| [`DynamicFeeHookV2`](../src/DynamicFeeHookV2.sol) | salt-mined hook (must encode `BEFORE_SWAP_FLAG | AFTER_SWAP_FLAG | BEFORE_SWAP_RETURNS_DELTA_FLAG | AFTER_SWAP_RETURNS_DELTA_FLAG`) | `Ownable2Step`. Owner can register vaults, ack failed distributions, set `maxFeeBps`. |
| [`LiquidityVaultV2`](../src/LiquidityVaultV2.sol) | EOA-deployable | `Ownable2Step` + `Pausable` + `ReentrancyGuard`. Owner can pause, set pool key (one-shot), set NAV anchor, set TVL cap, rescue native ETH. |
| [`FeeDistributor`](../src/FeeDistributor.sol) | EOA-deployable | `Ownable`. Owner can `retryDistribute`, `sweepUndistributed`, set hook/treasury. |

### Trust assumptions

- **Owner is honest-but-fallible.** All owner-only entrypoints are
  `Ownable2Step`'d (no single-tx ownership transfer). The owner can pause
  the vault and rotate the treasury, but cannot:
  - swap out the registered vault for a pool (`registerVault` is one-shot
    per pool — `VaultAlreadyRegistered` revert).
  - drain depositor assets directly: `rescueNative` only reaches native
    ETH dust; the V1 `rescueIdle` was removed in favour of full NAV
    accounting on both pool currencies (V1 H-2 closeout).
  - over-charge fees: `maxFeeBps` is capped at 1000 bps in code.
- **Distributor is non-blocking.** The hook's `afterSwap` wraps
  `distribute()` in a try/catch; a misconfigured distributor cannot DoS
  swaps. Failed amounts accrue in `failedDistribution[currency]` for
  later operator action.
- **Reserve offers are vault-initiated.** Only the address registered
  via `registerVault` can call `createReserveOffer` for a given pool.
  The hook cannot be coerced into selling currency it does not hold.
- **NAV anchor must be set before un-pausing.** `navReferenceSqrtPriceX96`
  is the deviation-guard reference. Until it is non-zero, the live spot
  is auto-bootstrapped on first deposit; once set, the deviation guard
  rejects any pool spot more than `maxNavDeviationBps` away (≤ 5%).

### Out of scope (still external trust)

- **Uniswap v4 `PoolManager`, `PositionManager`, `Permit2`.** Vendored
  versions and SHAs recorded in [`lib/VERSIONS.md`](../lib/VERSIONS.md).
- **OpenZeppelin v5 `ERC4626`, `Ownable2Step`, `Pausable`,
  `ReentrancyGuard`.** OZ `5.6.1` pinned to upstream SHA.
- **Solmate / forge-std / solmate-MockERC20** are test-only.

---

## 2. Attack surface map

### `DynamicFeeHookV2`

| Surface | Who can call | Invariants enforced |
|---------|--------------|---------------------|
| `beforeSwap` / `afterSwap` | `onlyPoolManager` | Reserve fill is sign-correct (`BeforeSwapDelta`), price-gated (offer ≥ AMM for swapper), inventory-bounded. Unit + integration + handler-driven fuzz coverage. |
| `createReserveOffer` | registered vault, `nonReentrant` | One offer per pool at a time; bounds `vaultSqrtPriceX96` to `[MIN_SQRT_PRICE, MAX_SQRT_PRICE)`; FoT-token check via balance snapshot. |
| `cancelReserveOffer` | registered vault, `nonReentrant` | Returns escrowed remainder; deactivates offer. |
| `claimReserveProceeds` | registered vault, `nonReentrant` | Pays out `proceedsOwed[vault][currency]`; cannot exceed accrued amount. |
| `acknowledgeFailedDistribution` | `onlyOwner` | Bookkeeping decrement of `failedDistribution[currency]`; under-flow guarded. |
| `setMaxFeeBps`, `registerVault` | `onlyOwner` | Bps cap; one-shot vault registration. |

**Conservation invariants** (proved by [`test/ReserveFillFuzzInvariants.t.sol`](../test/ReserveFillFuzzInvariants.t.sol)):

1. `hookBalance[c] ≥ escrowedReserve[vault][c] + proceedsOwed[vault][c]`
2. `ghostEscrowedIn[c] = ghostReturned[c] + ghostSold[c] + escrow[c]`
3. `ghostProceedsAccrued[c] = ghostClaimed[c] + proceeds[c]`
4. `totalReserveSold == Σ ghostSold[c]`
5. `offerActive ⇒ on-chain offer.active ∧ sellRemaining > 0`

### `LiquidityVaultV2`

| Surface | Who can call | Invariants enforced |
|---------|--------------|---------------------|
| `depositWithZap` / `mint` / `withdraw` / `redeem` | anyone, `whenNotPaused` | ERC-4626 share math with `_decimalsOffset() = 6`; first-deposit donation mitigated via pre-snapshot accounting + `minSharesOut`. NAV deviation-guarded. |
| `setPoolKey` | `onlyOwner`, one-shot | Permanent pool selection; cannot be re-pointed. |
| `refreshNavReference` | `onlyOwner` | Re-anchors NAV reference to current spot after a legitimate price move. |
| `setMaxNavDeviationBps` | `onlyOwner` | Capped at `MAX_NAV_DEVIATION_CAP = 500` bps (5%). |
| `pause` / `unpause` | `onlyOwner` | Halts deposits, withdraws, zaps. |
| `rescueNative` | `onlyOwner`, `nonReentrant` | Only path for SELFDESTRUCT-forced native ETH dust; receive/fallback both revert. |
| `setMaxTVL`, `setTreasury`, `setRemoveLiquiditySlippageBps`, `setTxDeadlineSeconds`, `setBootstrapRewards` | `onlyOwner` | Documented caps; treasury rejects `address(0)`; slippage capped at 1000 bps; deadline capped at 3600 s. |

### `FeeDistributor`

| Surface | Who can call | Invariants enforced |
|---------|--------------|---------------------|
| `distribute` | `onlyHook` | Splits incoming fee into treasury + LP donate; non-reverting paths preserved by the V2.2 try/catch in the hook. |
| `retryDistribute` | `onlyOwner`, `nonReentrant` | Replays a stuck distribution against current balance. |
| `sweepUndistributed` | `onlyOwner` | Restricted to currencies of the configured pool key. |
| `setHook`, `setPoolKey`, `setTreasury`, `setTreasuryShare` | `onlyOwner` | `treasuryShare` capped at 50%; treasury rejects `address(0)`. |

---

## 3. Operator runbook

### 3.1 Pre-deploy checklist

1. Mine the hook salt so address has flags
   `BEFORE_SWAP | AFTER_SWAP | BEFORE_SWAP_RETURNS_DELTA |
   AFTER_SWAP_RETURNS_DELTA`. Use [`test/utils/HookMiner.sol`](../test/utils/HookMiner.sol).
2. Deploy `FeeDistributor(poolManager, treasury, hook=address(0))`.
3. Deploy `DynamicFeeHookV2(poolManager, distributor, owner)` at the
   mined salt.
4. `distributor.setHook(hook)`. Hook is single-set.
5. Deploy `LiquidityVaultV2(...)`. **Do not unpause yet.**
6. `vault.setPoolKey(...)`. One-shot.
7. `hook.registerVault(poolKey, vault)`. One-shot per pool.
8. **Seed the NAV anchor.** Either (a) deposit a non-trivial founder
   stake — first-deposit auto-bootstraps `navReferenceSqrtPriceX96` —
   or (b) `vault.refreshNavReference()` after the pool is initialised.
9. `vault.setMaxTVL(100_000e6)` — start of staged ramp (see
   [`audits/TSI-Audit-Scanner_2026-04-25.md`](../audits/TSI-Audit-Scanner_2026-04-25.md) §4 of the V1 closeout).
10. `vault.unpause()`.

### 3.2 Failure-mode response

#### Failed distribution accrued at hook

**Symptom:** `FeeDistributionFailed(currency, amount)` event emitted by
hook; `hook.failedDistribution(currency)` non-zero.

**Diagnosis.** The hook held `amount` of `currency` and
`distributor.distribute(currency, amount)` reverted (treasury blacklist,
distributor not configured, etc.).

**Recovery.**

1. Identify and fix the distributor failure (`setTreasury`,
   `setPoolKey`, `setHook`, top up state as required).
2. Move the stuck balance from hook → distributor → recipients via
   `distributor.retryDistribute(currency, amount)` (uses live balance).
   Or, if the hook still holds the balance, route through
   `acknowledgeFailedDistribution` after manually transferring funds.
3. Once the funds have left the hook, call
   `hook.acknowledgeFailedDistribution(currency, amount)` to zero out
   the on-chain tally. Emits `FailedDistributionAcknowledged`.
4. As a last resort, `distributor.sweepUndistributed(currency, to,
   amount)` is restricted to pool-key currencies and bypasses the
   distribution split — use only with documented justification.

#### Native ETH dust at vault

**Symptom:** `address(vault).balance > 0`.

**Diagnosis.** Only path is forced via `SELFDESTRUCT`. `receive()` and
`fallback()` both revert (`NativeNotSupported`).

**Recovery.** `vault.rescueNative(to, amount)` — `onlyOwner`,
`nonReentrant`. Emits `NativeRescued(to, amount)`. There is no other
path; do not attempt to convert dust into shares.

#### NAV anchor drift / deviation guard tripping

**Symptom:** Deposits or withdraws revert with `NavDeviationExceeded`.

**Diagnosis.** Pool spot has moved more than `maxNavDeviationBps`
(default ≤ 500 bps = 5%) from `navReferenceSqrtPriceX96`. This is the
guard's intended behaviour when a sandwich or external mover has
nudged the price.

**Recovery.**

1. Confirm the move is legitimate (not an active manipulation) via
   off-chain telemetry (block-by-block spot, ref price, depth).
2. If legitimate, call `vault.refreshNavReference()` to re-anchor.
   Emits `NavReferenceRefreshed(old, new)`.
3. If under attack, **do not refresh**; pause the vault
   (`vault.pause()`), wait for the manipulation to revert via arbitrage,
   then refresh and unpause.

The deviation cap can be tightened (never raised above 500 bps) via
`setMaxNavDeviationBps`. It cannot be set above the constant cap; the
setter reverts `BPS_TOO_HIGH`.

#### Reserve offer needs cancellation

**Symptom:** Vault wants to recall escrowed reserve before a swap fills
it.

**Recovery.** `vault.cancelReserveOffer(sellCurrency)` — `onlyOwner`,
`nonReentrant`. The vault calls `hook.cancelReserveOffer(poolKey)` and
returns the escrowed remainder to the vault. Idempotent: a second call
on a non-active offer is a no-op revert path. Proceeds already accrued
to the vault (`proceedsOwed`) survive cancellation; claim them with
`hook.claimReserveProceeds(currency)` from the vault.

#### Emergency pause / rotation

| Scenario | Action |
|----------|--------|
| Suspected compromise of the hook salt-mined address | `vault.pause()` immediately. There is no in-place hook rotation; redeploy is required. |
| Suspected compromise of distributor | `vault.pause()`, then `distributor.setTreasury(newSafe)` and `distributor.setHook(...)` if rotating. Hook continues to soft-fail into `failedDistribution` until distributor is healthy. |
| Treasury key compromise | `distributor.setTreasury(newSafe)` and `vault.setTreasury(newSafe)`. Both reject `address(0)`. |
| Owner key compromise | Use `Ownable2Step` `acceptOwnership` from a fresh safe **before** the attacker can — there is no recovery once the attacker accepts. Consider a multisig owner from day one. |

### 3.3 Monitoring signals (off-chain)

| Source | Signal | Threshold |
|--------|--------|-----------|
| `hook.FeeDistributionFailed` | any emission | page on-call |
| `hook.failedDistribution(c)` | non-zero | reconcile within 24 h |
| `vault.balance` (native ETH) | > 0 | rescue, log forensics |
| `vault.NavReferenceRefreshed` | > 1 / 24 h | review price-feed and deviation cap |
| Live `(spot − ref) / ref` | > 80% of `maxNavDeviationBps` | warn (deposits will start reverting near 100%) |
| `hook.totalReserveSold` | unbounded growth | sanity-check against ghost expectation |
| Custom: hook ERC20 balance vs. `escrow + proceeds` | balance < escrow + proceeds | **never expected**; would indicate a conservation-invariant break — page immediately |

---

## 4. Audit-readiness summary

| Item | Status |
|------|--------|
| All V2.1 Tier-1 findings (T1.1–T1.6 + first-deposit donation) | ✅ FIXED |
| V2.1 residual R1 (volatility-oracle freeze) | ✅ MITIGATED in V2.2 |
| V2.1 residual R2 (no fuzz on `_tryFillReserve`) | ✅ FIXED in V2.2 (`test/ReserveFillFuzzInvariants.t.sol`) |
| V2.2 N1 (NAV anchor drift) | ✅ FIXED (`MAX_NAV_DEVIATION_CAP = 500`, two-step overflow-safe math) |
| V2.2 N2 (native ETH hygiene) | ✅ FIXED (revert receive/fallback + `rescueNative`) |
| V2.2 N3 (failed-distribution tally) | ✅ FIXED (`failedDistribution` + `acknowledgeFailedDistribution`) |
| V2.2 N4 (bootstrap auto-poke) | ✅ FIXED (`_update` override) |
| Test coverage | 221/221 passing (216 deterministic + 5 handler-driven fuzz invariants × 256 runs × 15 depth) |
| CI | [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) runs build + non-fork test on push/PR to `main` |
| Vendored dependency provenance | [`lib/VERSIONS.md`](../lib/VERSIONS.md) — forge-std + OZ pinned to upstream SHAs; v4-core / v4-periphery / solmate / permit2 marked TO-PIN with documented resolution failures |
| Operator runbook | this document |

### Known operational caveats (NOT deploy-blockers)

- **Founder seed-deposit recommended.** First-deposit donation is
  mitigated by `_decimalsOffset = 6` + `minSharesOut`, but a sufficiently
  large pre-first-deposit donation can grief share precision. Seed the
  vault from the deployer key.
- **Hook salt-mined address is permanent.** A future flag-set change
  requires a redeploy + migration, not an upgrade.
- **Vault registration is one-shot per pool at the hook layer.** A
  vault redeploy requires either (a) a new pool key or (b) a hook
  redeploy. There is no "rotate vault" path by design.

### Stack rating

**A.** The reserve-sale state machine has both deterministic and
random-sequence fuzz invariant coverage; operational failure modes have
explicit on-chain primitives rather than implicit assumptions. The
remaining `TO-PIN` rows in [`lib/VERSIONS.md`](../lib/VERSIONS.md) are
documentation, not contract changes, and do not affect the audit
verdict.
