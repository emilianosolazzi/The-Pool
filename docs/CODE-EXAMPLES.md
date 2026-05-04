# Value Calculator Code Examples - The Pool V2.1

These snippets are calculator primitives for the current V2.1 stack:

- `DynamicFeeHookV2`
- `FeeDistributor`
- `LiquidityVaultV2`
- `BootstrapRewards`

They are meant for frontends, dashboards, investor scenarios, and off-chain monitoring. For user-facing estimates, swap notional can be used as an approximation. For contract-accurate hook-fee accounting, the fee basis is the absolute value of the swap's unspecified-currency delta in `DynamicFeeHookV2.afterSwap`.

## Current V2.1 Assumptions

| Item | Value |
|---|---:|
| Base hook fee | `25 bps` |
| Volatile hook multiplier | `1.5x` |
| Default hook fee cap | `50 bps` |
| Max hook fee cap | `1000 bps` |
| FeeDistributor treasury share | `20 / 100` |
| FeeDistributor LP donation share | `80 / 100` |
| Deployed pool fee tier | `500` fee units = `5 bps` |
| Vault performance fee default | `400 bps` = `4%` |
| Bootstrap bonus share | `5000 bps` = `50%` of processed USDC treasury inflow |
| Bootstrap finalization delay | `7 days` after epoch end |
| Bootstrap claim window | `90 days` after finalization |

Live contract addresses are listed in [docs/DEPLOYED_ADDRESSES.md](DEPLOYED_ADDRESSES.md).

## JavaScript / TypeScript

### 1) Hook Fee Basis And Fee Currency

In V2, the hook fee is charged on the AMM-routed unspecified/output-side delta in `afterSwap`.

```ts
type FeeCurrencyInput = {
  zeroForOne: boolean;
  exactInput: boolean;
};

export function unspecifiedCurrencyIsCurrency1(input: FeeCurrencyInput): boolean {
  // Mirrors: bool unspecIsCurrency1 = params.zeroForOne == exactInput;
  return input.zeroForOne === input.exactInput;
}

export function absUnspecifiedDelta(delta: bigint): bigint {
  return delta < 0n ? -delta : delta;
}
```

For simple USD examples, `feeBasisAmount` can be approximated as swap notional. For exact accounting, use the absolute unspecified delta emitted/observed from v4 swap execution.

### 2) Hook Fee With Volatility And Cap

```ts
const BPS_DENOMINATOR = 10_000n;

type HookFeeInput = {
  feeBasisAmount: bigint;
  isVolatile: boolean;
  hookFeeBps?: bigint;
  maxFeeBps?: bigint;
};

export function computeHookFee({
  feeBasisAmount,
  isVolatile,
  hookFeeBps = 25n,
  maxFeeBps = 50n,
}: HookFeeInput): bigint {
  const multiplierPercent = isVolatile ? 150n : 100n;
  const base = (feeBasisAmount * hookFeeBps) / BPS_DENOMINATOR;
  const withVolatility = (base * multiplierPercent) / 100n;
  const cap = (feeBasisAmount * maxFeeBps) / BPS_DENOMINATOR;
  return withVolatility > cap ? cap : withVolatility;
}
```

This mirrors the contract's two-step floor behavior: first fee bps, then volatility multiplier, then cap.

### 3) Reserve Fill Gate

Reserve offers are checked in `beforeSwap` and only apply to exact-input swaps.

```ts
type ReservePricingMode = "PRICE_IMPROVEMENT" | "VAULT_SPREAD";

type ReserveGateInput = {
  sellingCurrency1: boolean;
  poolSqrtPriceX96: bigint;
  vaultSqrtPriceX96: bigint;
  pricingMode: ReservePricingMode;
};

export function reservePriceGatePass(input: ReserveGateInput): boolean {
  if (input.pricingMode === "PRICE_IMPROVEMENT") {
    return input.sellingCurrency1
      ? input.poolSqrtPriceX96 <= input.vaultSqrtPriceX96
      : input.poolSqrtPriceX96 >= input.vaultSqrtPriceX96;
  }

  return input.sellingCurrency1
    ? input.poolSqrtPriceX96 >= input.vaultSqrtPriceX96
    : input.poolSqrtPriceX96 <= input.vaultSqrtPriceX96;
}
```

Direction rule:

```text
vault sells currency1 -> fillable only on zeroForOne swaps
vault sells currency0 -> fillable only on oneForZero swaps
```

### 4) Reserve Fill Preview

This mirrors the high-level `DynamicFeeHookV2._tryFillReserve()` math with bigint floor division.

```ts
const Q96 = 1n << 96n;
const INT128_MAX = (1n << 127n) - 1n;

type ReserveFillInput = {
  exactInput: boolean;
  zeroForOne: boolean;
  maxInput: bigint;
  active: boolean;
  sellRemaining: bigint;
  sellingCurrency1: boolean;
  vaultSqrtPriceX96: bigint;
  poolSqrtPriceX96: bigint;
  pricingMode: ReservePricingMode;
  expiry?: bigint;
  nowTs?: bigint;
};

type ReserveFillPreview = {
  fillable: boolean;
  reason?: string;
  takeAmount: bigint;
  giveAmount: bigint;
  exhausted: boolean;
};

export function previewReserveFill(input: ReserveFillInput): ReserveFillPreview {
  const none = (reason: string): ReserveFillPreview => ({
    fillable: false,
    reason,
    takeAmount: 0n,
    giveAmount: 0n,
    exhausted: false,
  });

  if (!input.exactInput) return none("exact_output_swap");
  if (!input.active || input.sellRemaining === 0n) return none("inactive_offer");
  if (
    input.expiry !== undefined
    && input.expiry !== 0n
    && input.nowTs !== undefined
    && input.nowTs > input.expiry
  ) return none("expired_offer");
  if (input.sellingCurrency1 !== input.zeroForOne) return none("direction_mismatch");
  if (input.poolSqrtPriceX96 === 0n || input.vaultSqrtPriceX96 === 0n) return none("zero_price");
  if (input.maxInput === 0n) return none("zero_input");

  if (!reservePriceGatePass(input)) return none("price_gate");

  let takeCap: bigint;
  let takeAmount: bigint;
  let giveAmount: bigint;

  if (input.sellingCurrency1) {
    // zeroForOne. input=currency0, output=currency1=sellCurrency.
    const t1 = (input.sellRemaining * Q96) / input.vaultSqrtPriceX96;
    takeCap = (t1 * Q96) / input.vaultSqrtPriceX96;

    if (input.maxInput >= takeCap) {
      takeAmount = takeCap;
      giveAmount = input.sellRemaining;
    } else {
      takeAmount = input.maxInput;
      const m1 = (takeAmount * input.vaultSqrtPriceX96) / Q96;
      giveAmount = (m1 * input.vaultSqrtPriceX96) / Q96;
    }
  } else {
    // oneForZero. input=currency1, output=currency0=sellCurrency.
    const t2 = (input.sellRemaining * input.vaultSqrtPriceX96) / Q96;
    takeCap = (t2 * input.vaultSqrtPriceX96) / Q96;

    if (input.maxInput >= takeCap) {
      takeAmount = takeCap;
      giveAmount = input.sellRemaining;
    } else {
      takeAmount = input.maxInput;
      const m2 = (takeAmount * Q96) / input.vaultSqrtPriceX96;
      giveAmount = (m2 * Q96) / input.vaultSqrtPriceX96;
    }
  }

  if (takeAmount === 0n || giveAmount === 0n) return none("zero_fill");
  if (takeAmount > INT128_MAX || giveAmount > INT128_MAX) return none("int128_overflow");

  return {
    fillable: true,
    takeAmount,
    giveAmount,
    exhausted: giveAmount === input.sellRemaining,
  };
}
```

If the offer is expired, the hook skips the fill but does not automatically clear the raw storage active flag. Dashboards should distinguish raw active, expired, and fillable states.

### 5) Distributor Split

The distributor split applies only to hook fees routed through `FeeDistributor`. Native pool fees do not pass through this splitter.

```ts
export function splitHookFee(hookFee: bigint, treasuryShare = 20n) {
  // treasuryShare is percent units, not bps.
  // Example: 20n = 20%, matching FeeDistributor.treasuryShare.
  const treasuryAmount = (hookFee * treasuryShare) / 100n;
  const lpDonation = hookFee - treasuryAmount;
  return { treasuryAmount, lpDonation };
}
```

### 6) Vault Capture Estimate

Donations and pool fees are pool-level fee growth. The vault captures only its active in-range liquidity share.

```ts
type VaultCaptureInput = {
  lpDonation: number;
  poolFeeAmount: number;
  vaultActiveLiquidityShare: number;
  assetYieldFraction: number;
  performanceFeeBps: number;
};

export function estimateVaultCollectedYield(input: VaultCaptureInput) {
  // This is an analytics approximation. Real capture depends on active tick
  // liquidity at donation/swap time, range placement, LP inventory, and whether
  // the vault is in range.
  const grossCaptured = input.vaultActiveLiquidityShare * (input.lpDonation + input.poolFeeAmount);
  const grossAssetYield = grossCaptured * input.assetYieldFraction;
  const grossOtherValue = grossCaptured - grossAssetYield;
  const performanceFee = grossAssetYield * (input.performanceFeeBps / 10_000);
  const netAssetYield = grossAssetYield - performanceFee;

  return {
    grossCaptured,
    grossAssetYield,
    grossOtherValue,
    performanceFee,
    netAssetYield,
  };
}
```

Notes:

- `LiquidityVaultV2.totalYieldCollected` tracks net asset-token yield after performance fee.
- `otherTokenYieldCollected` tracks collected non-asset yield.
- `totalAssets()` also values idle other-token balance, reserve escrow, and pending reserve proceeds, so NAV can include value that is not counted in `totalYieldCollected`.
- If the vault is out of range, `vaultActiveLiquidityShare` may be zero.

### 7) Linear APR Proxy

`LiquidityVaultV2` does not expose an on-chain APR/APY projection helper. This is an analytics-side linear APR proxy, not compounded APY.

```ts
export function projectedAprBps(recentYield: number, windowSeconds: number, totalAssets: number) {
  if (windowSeconds === 0 || totalAssets === 0) return 0;
  const annualizedYield = (recentYield * 365 * 24 * 60 * 60) / windowSeconds;
  return (annualizedYield * 10_000) / totalAssets;
}
```

Optional compounded APY from a daily rate:

```ts
export function compoundedApyFromDailyRate(dailyRate: number) {
  return Math.pow(1 + dailyRate, 365) - 1;
}
```

### 8) BootstrapRewards Inflow Split

`BootstrapRewards.pullInflow()` processes only new payout-asset balance above already-tracked unclaimed bonus pools. Non-payout tokens do not fund USDC rewards.

```ts
type BootstrapInflowInput = {
  payoutAssetBalance: bigint;
  trackedUnclaimedBonusPools: bigint;
  currentEpochBonusPool: bigint;
  perEpochCap: bigint;
  bonusShareBps?: bigint;
  programActive: boolean;
};

export function splitBootstrapInflow(input: BootstrapInflowInput) {
  if (input.payoutAssetBalance <= input.trackedUnclaimedBonusPools) {
    return { processed: 0n, toBonusPool: 0n, toRealTreasury: 0n };
  }

  const processed = input.payoutAssetBalance - input.trackedUnclaimedBonusPools;
  if (!input.programActive) {
    return { processed, toBonusPool: 0n, toRealTreasury: processed };
  }

  const bonusShareBps = input.bonusShareBps ?? 5_000n;
  const rawBonus = (processed * bonusShareBps) / 10_000n;
  const headroom = input.perEpochCap > input.currentEpochBonusPool
    ? input.perEpochCap - input.currentEpochBonusPool
    : 0n;
  const toBonusPool = rawBonus > headroom ? headroom : rawBonus;
  const toRealTreasury = processed - toBonusPool;
  return { processed, toBonusPool, toRealTreasury };
}
```

### 9) BootstrapRewards Share-Seconds

This single-epoch helper mirrors the contract's conservative lazy-poke model. Production accounting must split intervals across epoch boundaries.

```ts
type ShareSecondsInput = {
  lastBalance: bigint;
  currentBalance: bigint;
  fromTs: bigint;
  toTs: bigint;
  firstDepositTime: bigint;
  dwellPeriod: bigint;
  perWalletShareCap: bigint;
  remainingEpochShareSecondsCap: bigint;
};

export function clippedShareSeconds(input: ShareSecondsInput): bigint {
  if (input.toTs <= input.fromTs || input.firstDepositTime === 0n) return 0n;

  const effectiveBalance = input.lastBalance < input.currentBalance
    ? input.lastBalance
    : input.currentBalance;
  const eligibleShares = effectiveBalance > input.perWalletShareCap
    ? input.perWalletShareCap
    : effectiveBalance;
  if (eligibleShares === 0n) return 0n;

  const dwellEnd = input.firstDepositTime + input.dwellPeriod;
  const start = input.fromTs > dwellEnd ? input.fromTs : dwellEnd;
  if (input.toTs <= start) return 0n;

  const rawContribution = (input.toTs - start) * eligibleShares;
  return rawContribution > input.remainingEpochShareSecondsCap
    ? input.remainingEpochShareSecondsCap
    : rawContribution;
}
```

Claim-window helpers:

```ts
const DAY = 24n * 60n * 60n;

export function isBootstrapEpochFinalized(nowTs: bigint, epochEnd: bigint, finalizationDelay = 7n * DAY) {
  return nowTs >= epochEnd + finalizationDelay;
}

export function isBootstrapClaimWindowOpen(
  nowTs: bigint,
  epochEnd: bigint,
  finalizationDelay = 7n * DAY,
  claimWindow = 90n * DAY,
) {
  const start = epochEnd + finalizationDelay;
  return nowTs >= start && nowTs < start + claimWindow;
}
```

## Solidity-Style Pseudocode Checks

### Hook Fee Path

```solidity
uint256 base = absUnspec * HOOK_FEE_BPS / 10_000;
uint256 fee = base * multiplierPercent / 100;
uint256 cap = absUnspec * maxFeeBps / 10_000;
if (fee > cap) fee = cap;
```

### Reserve Fill Gate

```solidity
if (params.amountSpecified >= 0) return ZERO_DELTA; // exact-output skip
if (!offer.active || offer.sellRemaining == 0) return ZERO_DELTA;
if (offer.expiry != 0 && block.timestamp > offer.expiry) return ZERO_DELTA;
if (offer.sellingCurrency1 != params.zeroForOne) return ZERO_DELTA;
```

### Distributor Split

```solidity
uint256 treasuryAmount = amount * treasuryShare / 100;
uint256 lpAmount = amount - treasuryAmount;
```

### Vault Performance Fee On Collected Asset Yield

```solidity
uint256 fee = assetGain * performanceFeeBps / 10_000;
uint256 netAssetYield = assetGain - fee;
```

### BootstrapRewards Inflow And Claim

```solidity
processed = payoutAsset.balanceOf(address(this)) - trackedUnclaimedBonusPools;
rawBonus = processed * bonusShareBps / 10_000;
toBonus = min(rawBonus, perEpochCap - currentEpochBonusPool);
toTreasury = processed - toBonus;

userPayout = epochBonusPool * userShareSeconds / totalShareSeconds;
```

## Scenario Inputs To Keep Explicit

Use these snippets as primitives, not forecasts. Keep these assumptions explicit in any UI or investor model:

- `feeBasisAmount` or swap notional approximation.
- Volatility-hit frequency.
- Reserve pricing mode, quote price, direction, expiry, and fillable state.
- Active in-range vault liquidity share.
- Pool fee tier.
- Asset-vs-other-token yield mix.
- Vault performance fee.
- Bootstrap program active state, payout-asset inflow, finalization delay, claim window, and caps.