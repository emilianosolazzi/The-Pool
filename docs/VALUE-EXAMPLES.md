# Value Math Examples - The Pool V2.1

This page gives numerical examples for the current V2.1 stack:

- `DynamicFeeHookV2`
- `FeeDistributor`
- `LiquidityVaultV2`
- `BootstrapRewards`

The examples are primitives for dashboards, investor scenarios, and operator discussions. They are not forecasts. For user-facing examples, swap notional can approximate the hook-fee basis. For contract-accurate accounting, the hook fee is computed on the absolute value of the AMM-routed unspecified-currency delta returned to `DynamicFeeHookV2.afterSwap`.

Live addresses and pool configuration are tracked in [docs/DEPLOYED_ADDRESSES.md](DEPLOYED_ADDRESSES.md). TypeScript calculator snippets are in [docs/CODE-EXAMPLES.md](CODE-EXAMPLES.md).

## 1. Current Assumptions

| Item | Current V2.1 value |
|---|---:|
| Base hook fee | `25 bps` |
| Volatile hook multiplier | `1.5x` |
| Default hook fee cap | `50 bps` |
| Hard hook fee cap | `1000 bps` |
| FeeDistributor treasury share | `20 / 100` |
| FeeDistributor LP donation share | `80 / 100` |
| Deployed pool fee tier | `500` fee units = `5 bps` |
| Vault performance fee default | `400 bps` = `4%` |
| Bootstrap bonus share | `5000 bps` = `50%` of processed USDC treasury inflow |
| Bootstrap per-epoch cap | `10,000 USDC` |
| Bootstrap finalization delay | `7 days` after epoch end |
| Bootstrap claim window | `90 days` after finalization |

## 2. Per-Swap Hook Fee

Contract mechanics:

```text
baseHookFee = absUnspecifiedDelta * 25 / 10_000
volatileHookFee = baseHookFee * 150 / 100
cap = absUnspecifiedDelta * maxFeeBps / 10_000
hookFee = min(baseHookFee or volatileHookFee, cap)
```

Notes:

- `absUnspecifiedDelta` is the absolute unspecified-currency delta from the v4 swap, not necessarily the user's input amount.
- For simple USD examples, use swap notional as an approximation.
- The fee currency is the unspecified currency selected by v4 swap semantics.
- The volatility multiplier applies only to the hook fee.
- Native pool fees are separate and are not multiplied by the hook volatility factor.
- The default cap is 50 bps, so the 37.5 bps volatile fee path is not capped under default settings.

## 3. FeeDistributor Split

`FeeDistributor.treasuryShare` uses percent units, not bps.

```text
treasuryAmount = hookFee * treasuryShare / 100
lpDonation = hookFee - treasuryAmount
```

At the current default split:

```text
treasuryAmount = hookFee * 20 / 100
lpDonation = hookFee * 80 / 100
```

This split applies only to hook fees routed through `FeeDistributor`. Native pool fees do not pass through this splitter.

## 4. Vault Capture

The vault does not automatically receive 100% of the LP donation or native pool fee. Donations and pool fees are pool-level fee growth. The vault captures only its active in-range liquidity share at the time of donation or fee accrual.

Let:

- `phi` = vault share of active in-range liquidity, from `0` to `1`.
- `poolFeeAmount` = native pool fee amount.
- `lpDonation` = hook-fee portion donated back into the pool.
- `assetYieldFraction` = share of captured value realized in the vault asset.

Analytics approximation:

```text
grossCaptured = phi * (lpDonation + poolFeeAmount)
grossAssetYield = grossCaptured * assetYieldFraction
grossOtherValue = grossCaptured - grossAssetYield
performanceFee = grossAssetYield * performanceFeeBps / 10_000
netAssetYield = grossAssetYield - performanceFee
```

Important caveats:

- Real capture depends on active tick liquidity at donation/swap time, range placement, LP inventory, and whether the vault is in range.
- If the vault is out of range, `phi` may be zero.
- `LiquidityVaultV2.totalYieldCollected` tracks net asset-token yield after performance fee.
- `otherTokenYieldCollected` tracks collected non-asset yield.
- `totalAssets()` can include idle other-token balance, reserve escrow, and reserve proceeds that are not counted in `totalYieldCollected`.

## 5. Worked Per-Swap Example

Assume:

- Swap notional approximation = `100,000 USDC`
- Not volatile
- `treasuryShare = 20`
- Vault active-liquidity share `phi = 1%`
- Pool fee tier = `5 bps`
- `assetYieldFraction = 100%`
- `performanceFeeBps = 400`

Base path:

```text
hookFee = 100,000 * 0.25% = 250
treasuryAmount = 250 * 20% = 50
lpDonation = 200

poolFeeAmount = 100,000 * 0.05% = 50
grossCaptured = 1% * (200 + 50) = 2.50
performanceFee = 2.50 * 4% = 0.10
netAssetYield = 2.40
```

Volatile path, before any cap change:

```text
hookFee = 250 * 1.5 = 375
treasuryAmount = 375 * 20% = 75
lpDonation = 300

poolFeeAmount = 50
grossCaptured = 1% * (300 + 50) = 3.50
performanceFee = 3.50 * 4% = 0.14
netAssetYield = 3.36
```

## 6. Daily Scenario Example

Assume:

- Daily swap volume `V = 1,000,000 USDC`
- Volatility-hit probability `p = 20%`
- Expected hook fee bps = `25 * (1 + 0.5 * p) = 27.5 bps`
- Pool fee tier = `5 bps`
- `treasuryShare = 20%`
- Vault active-liquidity share `phi = 1%`
- `assetYieldFraction = 100%`
- `performanceFeeBps = 400`
- Vault TVL used for the rate denominator = `100,000 USDC`

Step-by-step:

```text
hookFeesDaily = 1,000,000 * 0.275% = 2,750
lpDonationDaily = 2,750 * 80% = 2,200
poolFeesDaily = 1,000,000 * 0.05% = 500

grossCapturedDaily = 1% * (2,200 + 500) = 27
netAssetYieldDaily = 27 * (1 - 4%) = 25.92
dailyYieldRate = 25.92 / 100,000 = 0.02592%
```

This scenario assumes the vault is in range for the full day and all captured value is realized in the vault asset. If only part of the captured value is asset-denominated, apply the performance fee only to the asset-yield portion.

## 7. APR vs APY

`LiquidityVaultV2` does not expose an on-chain APR/APY projection helper. A common analytics-side linear APR proxy is:

```text
aprBps = recentYield * 365 days / windowSeconds * 10_000 / totalAssets
```

Using the daily scenario above:

```text
APR linear = 0.02592% * 365 = 9.46%
```

If a dashboard chooses to model external daily compounding:

```text
APY projected = (1 + 0.0002592)^365 - 1 = 9.93%
```

The compounded APY is an off-chain projection, not an on-chain return value.

## 8. Reserve-Spread Value Path

Reserve fills are not FeeDistributor fees. They are a separate path in `DynamicFeeHookV2.beforeSwap` where the vault can sell escrowed one-sided inventory to exact-input swappers before the AMM leg.

Steady-state LP-yield inventory should use `ReservePricingMode.VAULT_SPREAD` through the controller/keeper path. In this mode, the vault quotes at a controlled spread versus AMM spot and captures that spread as vault NAV if the offer fills.

Direction rule:

```text
vault sells currency1 / USDC -> fillable only on zeroForOne swaps
vault sells currency0 / WETH -> fillable only on oneForZero swaps
```

Simple approximation for a filled reserve sale:

```text
reserveSpreadValue ~= filledNotional * spreadBps / 10_000
```

Example:

```text
filledNotional = 20,000 USDC
spread = 25 bps
reserveSpreadValue ~= 20,000 * 0.25% = 50 USDC
```

Caveats:

- Exact fill math uses `vaultSqrtPriceX96`, pool spot, direction, sell currency, and bigint floor division.
- Expired offers are skipped but may remain raw-active in storage until cancelled or rebalanced.
- Reserve proceeds and escrow are included in vault NAV, but they are not `FeeDistributor` donations.

## 9. BootstrapRewards Math

The live BootstrapRewards program is documented in [docs/BOOTSTRAP.md](BOOTSTRAP.md). It is a temporary promotional rebate, not base protocol yield.

Live V2.1 defaults:

| Parameter | Value |
|---|---:|
| Bonus share | `5000 bps` = 50% |
| Per-epoch cap | `10,000 USDC` |
| Epoch length | `30 days` |
| Epoch count | `6` |
| Finalization delay | `7 days` |
| Claim window | `90 days` |
| Minimum dwell | `7 days` |
| Per-wallet cap | Deployment-time `25,000 USDC` share equivalent |
| Global cap | Deployment-time `100,000 USDC` share equivalent |

`pullInflow()` processes only new payout-asset balance above tracked unclaimed bonus pools:

```text
processed = payoutAsset.balanceOf(bootstrap) - trackedUnclaimedBonusPools
rawBonus = processed * bonusShareBps / 10_000
toBonus = min(rawBonus, perEpochCap - currentEpochBonusPool)
toRealTreasury = processed - toBonus
```

Example with cap headroom:

```text
processed USDC inflow = 1,000
rawBonus = 1,000 * 50% = 500
toBonus = 500
toRealTreasury = 500
```

Example near the per-epoch cap:

```text
processed USDC inflow = 25,000
current epoch headroom = 8,000
rawBonus = 12,500
toBonus = 8,000
toRealTreasury = 17,000
```

Base-fee shorthand before caps and payout-asset mix:

```text
hook fee = 25 bps of AMM-routed swap flow
treasury share = 25 bps * 20% = 5 bps
bootstrap bonus = 5 bps * 50% = 2.5 bps of USDC treasury-eligible flow
```

Only USDC payout-asset inflow funds USDC rewards. Non-payout assets sent to BootstrapRewards can be swept to the real treasury and do not become USDC bonus pool value automatically.

## 10. Practical Reading Guide

- Treat swap volume, volatility frequency, active in-range share, reserve spread, and asset-vs-other-token yield mix as scenario inputs.
- Treat hook-fee constants, FeeDistributor split rules, performance fee caps, and BootstrapRewards caps as contract-enforced mechanics.
- Label dashboard outputs as `APR linear` or `APY projected`; neither is an on-chain return promise.
- Separate the three value paths: native pool fees, hook-fee LP donations, and reserve-spread fills.
- Keep BootstrapRewards separate from base vault economics; it is capped, temporary, and only funded by processed USDC treasury inflow.