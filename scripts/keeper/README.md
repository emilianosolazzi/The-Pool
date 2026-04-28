# Reserve-offer keeper

Off-chain server keeper that posts and rebalances `VAULT_SPREAD`
reserve offers on `LiquidityVaultV2`. See
[`docs/HOOK-RISK-RUNBOOK.md`](../../docs/HOOK-RISK-RUNBOOK.md) §3.4 for
the policy.

## Requirements

- Node.js 20+
- The keeper key must be the vault `owner()` —
  `offerReserveToHookWithMode` and `rebalanceOfferWithMode` are both
  `onlyOwner`.

## Install

```bash
cd scripts/keeper
npm install
```

## Configure

```bash
export ARBITRUM_RPC_URL=https://arb1.arbitrum.io/rpc
export KEEPER_PRIVATE_KEY=0x...        # vault owner key
# Production (Arbitrum One, V2.1, Apr 2026):
export VAULT=0xf79c2dc829cd3a2d8ceec353bdb1b2414ba1eee0       # LiquidityVaultV2
export VAULT_LENS=0x12e86890b75fdee22a35be66550373936d883551  # VaultLens (vaultStatus reads)
export HOOK=0x486579DE6391053Df88a073CeBd673dd545200cC        # DynamicFeeHookV2

# Tunables (defaults shown)
export SPREAD_BPS=25
export REBALANCE_DRIFT_BPS=50
export MAX_OFFER_BPS_OF_IDLE=500       # 5% of idle asset per offer
export OFFER_TTL_SECONDS=900           # 15 min
export MIN_SELL_AMOUNT=1000000         # 1 USDC at 6 decimals
export INTERVAL_MS=60000               # base sleep between ticks
export JITTER_MS=15000                 # random extra sleep, [0, JITTER_MS]
export GAS_SAFETY_MULTIPLIER=3         # require expectedSpread >= 3 * gasCost
export ASSET_PER_NATIVE_E18=0          # asset units per 1e18 wei native;
                                       # 0 disables the profitability guard
```

## Run

```bash
# Dry run (simulates only)
npm run keeper:dry

# Single tick (broadcasts)
npm run keeper:once

# Loop (broadcasts every INTERVAL_MS, default 5 min)
npm run keeper:loop
```

## What it does each tick

1. Verifies the keeper key is the vault `owner()`.
2. Reads `vaultStatus()`. Skips on `PAUSED` / `UNCONFIGURED`.
3. Reads `getOfferHealth(poolKey, vault)` from the hook.
4. Reads `failedDistribution[asset]` from the hook and warns if > 0.
5. Computes `sellAmount = idleAsset * MAX_OFFER_BPS_OF_IDLE / 10_000`,
   skips if below `MIN_SELL_AMOUNT`.
6. Computes `vaultSqrtPriceX96` from current pool sqrtP and
   `SPREAD_BPS` (direction depends on which side of the pool `asset`
   sits — currency0 vs currency1).
7. If no active offer → `offerReserveToHookWithMode(..., VAULT_SPREAD)`.
   If active and `|driftBps| >= REBALANCE_DRIFT_BPS` →
   `rebalanceOfferWithMode(..., VAULT_SPREAD)`. Otherwise no-op.

## Production deployment (Contabo / systemd)

Drop a `systemd` unit at `/etc/systemd/system/the-pool-keeper.service`:

```ini
[Unit]
Description=The Pool reserve keeper
After=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/the-pool/scripts/keeper
EnvironmentFile=/etc/the-pool/keeper.env
ExecStart=/usr/bin/npm run keeper:loop
Restart=always
RestartSec=10
User=keeper

[Install]
WantedBy=multi-user.target
```

`/etc/the-pool/keeper.env` should contain the env vars from
**Configure** above and be `chmod 600 root:keeper`.

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now the-pool-keeper
sudo journalctl -u the-pool-keeper -f
```
