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
export READ_ONLY=false                 # true = metrics-only, no key/writes
export INTERVAL_MS=60000               # base sleep between ticks
export JITTER_MS=15000                 # random extra sleep, [0, JITTER_MS]
export GAS_SAFETY_MULTIPLIER=3         # require expectedSpread >= 3 * gasCost
export ASSET_PER_NATIVE_E18=0          # asset units per 1e18 wei native;
                                       # 0 disables the profitability guard

# Optional telemetry / alerting
export METRICS_HOST=127.0.0.1          # Prometheus scrape bind address
export METRICS_PORT=0                  # 0 disables; use 9464 for /metrics
export ALERT_WEBHOOK_URL=              # Slack/Discord-compatible webhook
export ALERT_COOLDOWN_SECONDS=600
```

## Run

```bash
# Dry run (simulates only)
npm run keeper:dry

# Single tick (broadcasts)
npm run keeper:once

# Loop (broadcasts every INTERVAL_MS, default 1 min)
npm run keeper:loop

# Loop with local Prometheus metrics enabled
METRICS_PORT=9464 npm run keeper:loop
curl http://127.0.0.1:9464/metrics

# Read-only metrics loop (real chain reads, no private key required)
READ_ONLY=true DRY_RUN=true LOOP=true METRICS_PORT=9464 npx tsx reserveKeeper.ts
```

## Prometheus telemetry (no Docker)

The keeper exposes Prometheus text-format metrics directly from Node's
built-in HTTP server when `METRICS_PORT` is non-zero. No exporter,
container, or `prom-client` dependency is required. Keep the default
`METRICS_HOST=127.0.0.1` when Prometheus runs on the same VM; if you
scrape from another host, bind only to a private interface or VPN address
and firewall the port.

Set `READ_ONLY=true` for a scrape-only process that publishes real on-chain
reserve state without loading `KEEPER_PRIVATE_KEY` or evaluating write
actions. This is the safest mode for a public Grafana VM.

Example keeper env for a local Prometheus scrape:

```env
METRICS_HOST=127.0.0.1
METRICS_PORT=9464
```

The repo includes a minimal standalone Prometheus config at
[`prometheus.yml`](./prometheus.yml):

```bash
sudo mkdir -p /etc/prometheus /var/lib/prometheus
sudo cp prometheus.yml /etc/prometheus/prometheus.yml
```

Install Prometheus from the upstream Linux tarball rather than Docker:

```bash
curl -LO https://github.com/prometheus/prometheus/releases/download/v<VERSION>/prometheus-<VERSION>.linux-amd64.tar.gz
tar xzf prometheus-<VERSION>.linux-amd64.tar.gz
sudo install -m 0755 prometheus-<VERSION>.linux-amd64/prometheus /usr/local/bin/prometheus
sudo install -m 0755 prometheus-<VERSION>.linux-amd64/promtool /usr/local/bin/promtool
sudo useradd --system --no-create-home --shell /usr/sbin/nologin prometheus
sudo chown -R prometheus:prometheus /etc/prometheus /var/lib/prometheus
promtool check config /etc/prometheus/prometheus.yml
```

Optional systemd unit for Prometheus at
`/etc/systemd/system/prometheus.service`:

```ini
[Unit]
Description=Prometheus monitoring
After=network-online.target

[Service]
Type=simple
User=prometheus
Group=prometheus
ExecStart=/usr/local/bin/prometheus \
   --config.file=/etc/prometheus/prometheus.yml \
   --storage.tsdb.path=/var/lib/prometheus \
   --web.listen-address=127.0.0.1:9090
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

Enable it with:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now prometheus
curl http://127.0.0.1:9090/api/v1/targets
```

## Grafana dashboard (no Docker)

Grafana reads the keeper through Prometheus: keeper `/metrics` →
Prometheus `the-pool-keeper` scrape job → Grafana datasource/dashboard.
The repo includes provisioning files under [`grafana`](./grafana) so a
fresh Grafana instance starts with the Prometheus datasource and keeper
dashboard already connected.

Install Grafana from the official apt repository on the VM (no Docker):

```bash
sudo apt-get update
sudo apt-get install -y apt-transport-https software-properties-common wget gpg
sudo mkdir -p /etc/apt/keyrings
wget -q -O - https://apt.grafana.com/gpg.key | gpg --dearmor | \
   sudo tee /etc/apt/keyrings/grafana.gpg >/dev/null
echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" | \
   sudo tee /etc/apt/sources.list.d/grafana.list
sudo apt-get update
sudo apt-get install -y grafana
```

Copy the provisioning files:

```bash
sudo mkdir -p \
   /etc/grafana/provisioning/datasources \
   /etc/grafana/provisioning/dashboards \
   /var/lib/grafana/dashboards/the-pool

sudo cp grafana/provisioning/datasources/prometheus.yml \
   /etc/grafana/provisioning/datasources/the-pool-prometheus.yml
sudo cp grafana/provisioning/dashboards/the-pool-keeper.yml \
   /etc/grafana/provisioning/dashboards/the-pool-keeper.yml
sudo cp grafana/dashboards/the-pool-keeper.json \
   /var/lib/grafana/dashboards/the-pool/the-pool-keeper.json
sudo chown -R grafana:grafana /var/lib/grafana/dashboards
```

Bind Grafana to localhost and verify it is healthy:

```bash
sudo mkdir -p /etc/systemd/system/grafana-server.service.d
cat <<'EOF' | sudo tee /etc/systemd/system/grafana-server.service.d/override.conf >/dev/null
[Service]
Environment=GF_SERVER_HTTP_ADDR=127.0.0.1
Environment=GF_SERVER_HTTP_PORT=3000
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now grafana-server
curl http://127.0.0.1:3000/api/health
```

Open the UI through an SSH tunnel instead of exposing port 3000:

```bash
ssh -L 3000:127.0.0.1:3000 <user>@<keeper-vm>
```

Then visit `http://127.0.0.1:3000/d/the-pool-keeper/the-pool-keeper`.
The default local datasource URL is `http://127.0.0.1:9090`; change
[`grafana/provisioning/datasources/prometheus.yml`](./grafana/provisioning/datasources/prometheus.yml)
if Prometheus runs elsewhere.

## Public Grafana dashboard (separate, no login)

The operator dashboard above should stay private. For a public participant
view, run a second Grafana instance with only the curated public dashboard
from [`grafana-public`](./grafana-public). It uses the same local
Prometheus datasource, but provisions only participant-safe panels: offer
state, data freshness, quote drift, idle USDC, settlement backlog, vault
TVL, share price, depositor count, offer inventory/expiry, reserve fills,
reserve-update activity, and published reserve policy. The offer state is
derived as `none` / `live` / `expired`, so an expired storage-active offer
does not appear live to participants.

Copy the public provisioning bundle into separate Grafana paths:

```bash
sudo mkdir -p \
   /etc/grafana-public/provisioning/datasources \
   /etc/grafana-public/provisioning/dashboards \
   /var/lib/grafana-public/dashboards/the-pool \
   /var/lib/grafana-public/plugins \
   /var/log/grafana-public

sudo cp grafana-public/provisioning/datasources/prometheus.yml \
   /etc/grafana-public/provisioning/datasources/the-pool-prometheus.yml
sudo cp grafana-public/provisioning/dashboards/the-pool-public.yml \
   /etc/grafana-public/provisioning/dashboards/the-pool-public.yml
sudo cp grafana-public/dashboards/the-pool-public-reserve.json \
   /var/lib/grafana-public/dashboards/the-pool/the-pool-public-reserve.json
sudo chown -R grafana:grafana /etc/grafana-public /var/lib/grafana-public /var/log/grafana-public
```

Create `/etc/systemd/system/grafana-public.service`:

```ini
[Unit]
Description=The Pool public Grafana dashboard
After=network-online.target prometheus.service

[Service]
Type=simple
User=grafana
Group=grafana
Environment=GF_SERVER_HTTP_ADDR=0.0.0.0
Environment=GF_SERVER_HTTP_PORT=3001
Environment=GF_AUTH_ANONYMOUS_ENABLED=true
Environment=GF_AUTH_ANONYMOUS_ORG_ROLE=Viewer
Environment=GF_AUTH_DISABLE_LOGIN_FORM=true
Environment=GF_USERS_ALLOW_SIGN_UP=false
Environment=GF_EXPLORE_ENABLED=false
Environment=GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH=/var/lib/grafana-public/dashboards/the-pool/the-pool-public-reserve.json
ExecStart=/usr/sbin/grafana-server \
   --homepath=/usr/share/grafana \
   --config=/etc/grafana/grafana.ini \
   --packaging=deb \
   cfg:default.paths.data=/var/lib/grafana-public \
   cfg:default.paths.logs=/var/log/grafana-public \
   cfg:default.paths.plugins=/var/lib/grafana-public/plugins \
   cfg:default.paths.provisioning=/etc/grafana-public/provisioning
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

Start it and use the URL directly, no Grafana login or wallet required:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now grafana-public
curl http://127.0.0.1:3001/api/health
```

Public URL: `http://<keeper-vm>:3001/d/the-pool-public-reserve/the-pool-public-reserve-desk`.
For production, put that behind TLS/reverse proxy and expose only the public
Grafana instance; keep Prometheus and the operator Grafana on localhost.

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
**Configure** above and be `chmod 600 root:keeper`. To enable local
Prometheus scraping on the same host, add:

```env
METRICS_HOST=127.0.0.1
METRICS_PORT=9464
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now the-pool-keeper
sudo journalctl -u the-pool-keeper -f
```
