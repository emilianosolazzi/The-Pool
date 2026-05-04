# The Pool - Early Depositor Bootstrap Program

Public spec. Status: implemented at [src/BootstrapRewards.sol](../src/BootstrapRewards.sol). Tests at [test/BootstrapRewards.t.sol](../test/BootstrapRewards.t.sol) (27 unit tests).

This document describes the current V2.1 bootstrap program and deployed defaults. The program is a temporary promotional rebate layered on top of the normal vault economics; it is not a token, not a permanent emissions program, and not a guarantee of yield.

## 1. Offer

> **Early Depositor Bonus - first $100K-equivalent vault shares, 180 days.**
> During the program window, eligible depositors share 50% of USDC treasury-fee inflows that reach the bootstrap contract.
> Rewards are time-weighted by vault shares held, paid in monthly epochs after finalization, capped, non-transferable, and paid in USDC.

This is a yield kicker on top of the normal LP-side hook donation and pool fee economics. It does not change the base hook, vault, or ERC-4626 share mechanics.

## 2. Live V2.1 Wiring

Current production addresses are tracked in [docs/DEPLOYED_ADDRESSES.md](DEPLOYED_ADDRESSES.md).

| Item | Current V2.1 value |
|---|---|
| Bootstrap contract | `0x3E6Ed05c1140612310DDE0d0DDaAcCA6e0d7a03d` |
| Vault | `0xf79c2dc829cd3a2d8ceec353bdb1b2414ba1eee0` |
| FeeDistributor | `0x5757DA9014EE91055b244322a207EE6F066378B0` |
| Payout asset | Native USDC, the vault asset |
| Program start | `1777348921` |
| Program end | `1792900921` |
| Wiring | `FeeDistributor.treasury = BootstrapRewards`; `BootstrapRewards.realTreasury = Ledger`; `LiquidityVaultV2.bootstrapRewards = BootstrapRewards` |

The FeeDistributor can send treasury fees in either pool currency. Only payout-asset inflows, currently USDC, fund the USDC bonus pool. Non-payout assets sent to the bootstrap contract are swept to the real treasury through `sweepToken()`.

## 3. Parameters

| Parameter | Value | Notes |
|---|---|---|
| Program duration | 180 days from `programStart` | Six 30-day epochs. |
| Epoch length | 30 days | Monthly accounting window. |
| Finalization delay | 7 days after each epoch ends | Anyone can still `poke()` users; claims are locked until this delay passes. |
| Claim window | 90 days after finalization | Unclaimed amounts can be swept to real treasury after the window closes. |
| Bonus share | 50% of processed USDC treasury inflow | `bonusShareBps = 5000`; the remainder forwards to real treasury. |
| Per-epoch bonus cap | 10,000 USDC | Excess USDC inflow forwards to real treasury. |
| Eligible TVL cap | 100,000 USDC converted to vault shares at deployment | Matches the independent human-audit trigger in [README.md](../README.md). Per epoch, total eligible share-seconds are capped as if at most this share amount were eligible for the full epoch. |
| Per-wallet cap | 25,000 USDC converted to vault shares at deployment | Balances above the cap are clipped, not excluded. |
| Minimum dwell | 7 days continuous nonzero share balance before accrual starts | Anti-flash-deposit rule. |
| Accounting unit | Share-seconds | Time-weighted by eligible vault shares. |
| Transfer behavior | Address-based eligibility with vault auto-pokes | Share transfers are not portable bonus claims; the recipient has its own dwell/accrual state. |
| Payout asset | USDC | No new token, no vesting wrapper. |

The share caps are fixed at deployment by calling `vault.convertToShares()` on the USDC cap amounts. If vault share price changes later, the USDC-equivalent value of those fixed share caps may differ from the original dollar labels.

## 4. Contract Math

`pullInflow()` is permissionless and idempotent. It processes only new payout-asset balance above already-tracked bonus pools:

```text
processed = payoutAsset.balanceOf(bootstrap) - trackedUnclaimedBonusPools
```

If the program has not started or has already ended, all processed USDC forwards to `realTreasury`. During an active epoch:

```text
rawBonus = processed * bonusShareBps / 10_000
toBonus = min(rawBonus, perEpochCap - currentEpochBonusPool)
toTreasury = processed - toBonus
```

For each user and epoch:

```text
eligibleShares = min(userShareBalance, perWalletShareCap)
userShareSeconds += eligibleShares * eligibleSecondsAfterDwell
```

The implementation uses a conservative lazy-poke model. For an unpoked interval, accrual is based on `min(lastBalance, currentBalance)`, so an unpoked balance reduction cannot over-credit a user. Unpoked balance increases do not retroactively boost accrual.

Epoch-wide eligible share-seconds are capped:

```text
epochTotalShareSeconds <= globalShareCap * epochLength
```

User payout after finalization:

```text
userPayout = epochBonusPool * userShareSeconds / totalShareSeconds
```

`claim(epoch)` calls `_poke(msg.sender)` first, then pays pull-style if the epoch is finalized, the claim window is open, and the user has unclaimed share-seconds.

## 5. Illustrative Magnitude

Base-fee illustration, before impermanent loss, gas, vault performance fee, range downtime, reserve effects, volatility multiplier, fee cap changes, payout-asset mix, and program caps:

```text
base hook fee = 25 bps of AMM-routed swap flow
LP-side donation = 25 bps * 80% = 20 bps
treasury share = 25 bps * 20% = 5 bps
bootstrap bonus = 5 bps * 50% = 2.5 bps of USDC treasury-eligible flow
```

| Daily volume / active TVL | LP-side hook donation APY (20 bps) | Bootstrap bonus APY while eligible (2.5 bps) | Combined hook-funded gross APY while eligible |
|---|---:|---:|---:|
| 0.10x | 7.30% | 0.91% | 8.21% |
| 0.25x | 18.25% | 2.28% | 20.53% |
| 0.50x | 36.50% | 4.56% | 41.06% |
| 1.00x | 73.00% | 9.13% | 82.13% |

The LP-side donation is pool-level fee growth for all in-range LPs. The bootstrap bonus is narrower: it is only for eligible vault shareholders and only from processed USDC treasury inflows during active epochs.

Six-month bonus allocation before and after the 10,000 USDC per-epoch cap:

| Sustained daily USDC-eligible volume | 180-day bonus before cap | With 10,000 USDC/epoch cap |
|---|---:|---:|
| 100,000 USDC | 4,500 USDC | 4,500 USDC |
| 300,000 USDC | 13,500 USDC | 13,500 USDC |
| 1,000,000 USDC | 45,000 USDC | 45,000 USDC |
| 1,340,000 USDC+ | 60,300 USDC+ | 60,000 USDC |

## 6. Anti-Gaming Rules

| Vector | Control |
|---|---|
| Flash deposit or same-block farming | 7-day dwell before share-seconds accrue. |
| One wallet dominating rewards | Per-wallet cap clips eligible shares to the deployment-time 25,000 USDC share equivalent. |
| Program over-allocation | Per-epoch bonus cap and epoch-wide global share-seconds cap. |
| Sybil splitting | Not fully solvable on-chain; returns are bounded by the 100,000 USDC global share cap and 10,000 USDC per-epoch bonus cap. |
| Share transfer farming | Eligibility is address-based. Vault share movements auto-poke both sides, and recipients have their own dwell/accrual state. |
| Lazy-poke over-crediting after withdrawals | Accrual uses the lower of last recorded and current balance for the unpoked interval. |
| Wash trading to inflate treasury fees | Attackers still pay hook fees, pool execution costs, spread/slippage, and gas; volatile moves can increase hook fees, and bonus payouts are capped per epoch. |
| Foreign-token treasury inflow | Non-USDC assets do not fund the USDC bonus pool; owner sweeps them to real treasury. |

## 7. Operational Notes

- `pullInflow()` can be called by anyone and should be run by keeper/UI automation when USDC has accumulated on the bootstrap contract.
- `poke(user)` can be called by anyone. `LiquidityVaultV2` auto-pokes configured BootstrapRewards on mint, burn, and transfer, but frontends can still batch-poke known users before finalization or claims.
- `claim(epoch)` opens only after epoch end plus the 7-day finalization delay, and only during the 90-day claim window.
- `sweepEpoch(epoch)` can be called by anyone after the claim window closes; it returns unclaimed USDC to real treasury.
- `sweepToken(token)` is owner-only and cannot sweep the payout asset.
- `setRealTreasury(newTreasury)` is owner-only.

## 8. Caveats

- This is a temporary promotional rebate, not protocol yield and not a return promise.
- Rewards depend on processed USDC treasury inflow. Hook fees paid in non-USDC currencies do not automatically become USDC rewards.
- Share-seconds accrue only after 7 days of continuous nonzero balance.
- Share caps are deployment-time share caps; their later USDC-equivalent value can move with vault share price.
- Program caps can limit rewards even if volume is higher.
- Impermanent loss, range placement, reserve execution, keeper uptime, gas, and smart-contract risk are unchanged by the program.
- The vault can hold idle USDC, other-token inventory, reserve escrow/proceeds, and v4 liquidity. When liquidity is active and in range, vault inventory can change composition.
- Owner controls exist: vault pause, vault performance fee up to 20%, hook fee cap up to 10%, treasury share up to 50%, real-treasury updates, and non-payout-token sweeps.
- Internal automated review is not a substitute for a third-party human audit. TSI Audit Scanner reports are in [audits/TSI-Audit-Scanner_2026-04-25.md](../audits/TSI-Audit-Scanner_2026-04-25.md) and [audits/TSI-Audit-Scanner_2026-04-27.md](../audits/TSI-Audit-Scanner_2026-04-27.md). The operational companion is [docs/HOOK-RISK-RUNBOOK.md](HOOK-RISK-RUNBOOK.md). The project README documents the independent human-audit trigger at 100,000 USDC TVL.

## 9. Public Summary

- A fixed share of USDC treasury fees is routed to an early-depositor bonus program for 180 days.
- Rewards are time-weighted by eligible vault shares and continuous holding time.
- Per-wallet, per-epoch, and global eligibility caps keep the program bounded.
- Rewards are pull-claimed in USDC after monthly epochs finalize.
- The program is additive to normal LP economics and does not change base hook/vault behavior.