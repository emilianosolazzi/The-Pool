# The Pool - Investor Overview

The Pool is a Uniswap v4 hook protocol that turns swap activity into measurable LP-side fee flow.

When traders route through the hooked pool, the hook captures a programmable fee, routes most of that value back to in-range LPs through Uniswap v4 donation mechanics, and lets an ERC-4626 vault package the strategy into shares. Depositors enter with USDC, receive vault shares, and participate pro rata as the vault collects and redeploys yield.

The thesis is simple: if the pool attracts sustained volume and the vault remains active in range, swap activity can translate into higher vault assets per share. The model below is scenario-based and uses protocol fee mechanics, not emissions, token incentives, or off-chain promises.

## Why The Stack Is Interesting

The Pool is built around five investor-relevant properties:

1. **Volume-native revenue**
   Revenue comes from swap activity. The protocol does not need a token, inflation budget, or mercenary emissions to create yield.

2. **Fee flow goes back to liquidity**
   The default split routes 80% of hook fees back to LP-side fee growth through `poolManager.donate()`. This means volume can directly improve the economics of in-range liquidity.

3. **ERC-4626 share accounting**
   Depositors receive vault shares. As yield is collected, vault assets rise and share price can appreciate. Users do not need a separate staking or claim flow for core vault yield.

4. **Dynamic upside in volatile periods**
   The base hook fee is 25 bps. In volatile blocks, the hook can scale that fee by 1.5x, subject to the configured fee cap. This gives the strategy more fee capture when trading conditions are more active.

5. **Public transparency layer**
   The keeper, Prometheus, and Grafana stack can expose public metrics for vault TVL, share price, depositors, reserve offer state, quote drift, reserve fills, and freshness. Investors can inspect live operational state instead of relying only on screenshots.

Important constraint: the vault only earns fee flow while its liquidity is active and in range. If price moves outside the selected tick band, capital can sit partially idle in USDC until the range is repositioned or reserve activity converts inventory. Keeper automation and controller/Safe-governed operations are designed to reduce this risk, but they do not remove market, range, execution, or smart-contract risk.

## How Deposits Become Shares

The vault is ERC-4626. Deposits mint shares using the live share price:

```text
shares minted = deposit amount / current share price
```

If share price is `1.00`, a `10,000 USDC` deposit mints roughly `10,000` shares. If share price rises to `1.05`, the same deposit mints roughly `9,523.81` shares. Existing shareholders benefit when share price rises because each share represents more underlying assets.

The number of depositors does not change ROI by itself. What matters is:

- Total USDC deposited
- How much of the vault liquidity is active and in range
- Daily swap volume through the pool
- Fee settings and performance fee
- Keeper quality and rebalance freshness

## Capital Formation Scenarios

The table below shows how much vault capital is formed if 1 to 10 liquidity wallets deposit between `1,000` and `100,000 USDC` each.

| Wallets | Deposit Each | Total Vault Capital Added |
|---:|---:|---:|
| 1 | 1,000 USDC | 1,000 USDC |
| 1 | 10,000 USDC | 10,000 USDC |
| 1 | 100,000 USDC | 100,000 USDC |
| 5 | 1,000 USDC | 5,000 USDC |
| 5 | 10,000 USDC | 50,000 USDC |
| 5 | 100,000 USDC | 500,000 USDC |
| 10 | 1,000 USDC | 10,000 USDC |
| 10 | 10,000 USDC | 100,000 USDC |
| 10 | 100,000 USDC | 1,000,000 USDC |

Equal-size depositors receive equal economic exposure. In a 10-wallet cohort where each wallet deposits the same amount, each wallet owns about 10% of the new cohort's vault exposure.

## Fee Mechanics Behind The ROI Model

The protocol's simplified expected fee model is:

```text
base hook fee = 25 bps of swap flow
volatile hook fee = 25 bps * 1.5, when the volatility condition is hit
LP-side hook share = hook fee * 80%
pool fee tier = 5 bps on the reference USDC/WETH pool
vault performance fee = 4% of collected asset-token yield
```

For a positive but reasonable volume model, assume volatility is hit on 20% of flow:

```text
expected hook fee = 25 bps * (1 + 0.5 * 20%) = 27.5 bps
LP-side hook donation = 27.5 bps * 80% = 22.0 bps
pool fee contribution = 5.0 bps
gross LP-side fee flow = 27.0 bps
after 4% performance fee = 25.92 bps net fee flow
```

The vault earns its share of that fee flow while its liquidity is active and in range:

```text
vault net daily yield = daily swap volume * 0.002592 * vault active-liquidity share
```

If the vault supplies a meaningful share of the active liquidity, the same pool volume can create meaningful vault APR.

## Scenario APR: When Volume, Range, And Depth Align

The most useful investor lens is APR per active-liquidity depth. If the vault is active and in range, its approximate APR is:

```text
APR ~= daily volume * 0.002592 * 365 / active liquidity depth
```

In this formula, `active liquidity depth` means the capital actually competing for fees inside the active price range, not total vault TVL sitting idle or out of range.

These are linear scenario outputs, not forecasts. They assume the vault is active, in range, receives its modeled share of fee flow, and that volume is sustained. They do not include impermanent loss, out-of-range idle time, rebalance timing, gas, adverse selection, or execution slippage.

| Daily Swap Volume | Active Liquidity Depth | Modeled Linear APR |
|---:|---:|---:|
| 1,000,000 USDC | 1,000,000 USDC | 94.6% |
| 1,000,000 USDC | 5,000,000 USDC | 18.9% |
| 1,000,000 USDC | 10,000,000 USDC | 9.5% |
| 5,000,000 USDC | 5,000,000 USDC | 94.6% |
| 5,000,000 USDC | 10,000,000 USDC | 47.3% |
| 5,000,000 USDC | 25,000,000 USDC | 18.9% |
| 10,000,000 USDC | 10,000,000 USDC | 94.6% |
| 10,000,000 USDC | 25,000,000 USDC | 37.8% |
| 10,000,000 USDC | 50,000,000 USDC | 18.9% |

These scenarios show why the design is attractive when two things happen together:

- The pool attracts real daily swap volume.
- The vault supplies in-range liquidity that participates in that flow.

## What 10k To 100k Deposits Can Mean

For early liquidity, the first useful milestones are not abstract. They are simple capital-and-volume combinations.

| Liquidity Added | What It Proves | Investor Read |
|---:|---|---|
| 10,000 USDC | The vault can accept real capital and mint shares cleanly. | Early product validation. |
| 50,000 USDC | Multiple wallets can coordinate meaningful LP exposure. | Stronger beta signal. |
| 100,000 USDC | The vault becomes worth monitoring as a live strategy. | Diligence-ready. |
| 500,000 USDC | Fee capture becomes easier to observe over normal market movement. | Investor-demo strong. |
| 1,000,000 USDC | The strategy can show whether volume converts into durable share-price growth. | Fundraising-relevant if operations stay healthy. |

At these capital levels, ROI still depends on volume. The positive case is that volume turns the vault from a passive LP wrapper into a live fee-capture product whose share price can appreciate as swap activity compounds through the system.

## Why This Can Scale

The Pool can scale because the mechanics are simple and repeatable:

- More volume creates more fee flow.
- More in-range vault liquidity captures a larger share of that fee flow.
- Harvested yield raises vault assets.
- Higher assets support higher share price.
- Public telemetry can show whether the system is fresh, in range, and filling reserve activity.

The stack is not betting on a one-time incentive campaign. It is betting on a durable market structure: liquidity earns when traders trade.

## What Investors Should Watch

The positive dashboard story should focus on these metrics:

| Metric | Why It Matters |
|---|---|
| Vault TVL | Shows capital formation and capacity. |
| Share price | Shows whether vault assets per share are increasing. |
| Depositors | Shows participation breadth. |
| Data freshness | Shows telemetry and keeper visibility are alive. |
| Offer state | Shows whether reserve-sale inventory is live, expired, or absent. |
| Quote drift | Shows whether reserve offers need upkeep. |
| Reserve fills | Shows actual reserve-sale activity. |
| Settlement backlog | Shows whether unresolved distribution accounting exists. |
| Published reserve policy | Shows the spread and rebalance thresholds governing keeper behavior. |

The private operator dashboard should remain separate. Investor-facing telemetry should be clean, readable, and limited to data that supports trust.

## Positive Investor Thesis

The Pool gives investors a clear volume-to-yield story:

```text
swap volume -> hook fees -> LP-side donation -> vault yield -> higher share price
```

If volume arrives, the upside is visible and measurable. A `100,000` to `1,000,000 USDC` early liquidity cohort can make the strategy materially observable, while public Grafana can show the market how TVL, share price, reserve activity, and freshness evolve over time.

The best version of the story is not speculative hype. The Pool is designed to be a transparent volume-to-yield system: simple deposits, ERC-4626 shares, volume-linked yield, and public metrics that let investors watch the system work.

## Reading The Numbers Responsibly

The tables above are scenario outputs. They are useful for understanding the opportunity, but they are not guaranteed returns. Actual ROI depends on trading volume, pool depth, range placement, keeper uptime, market volatility, execution costs, and smart-contract risk.

The upside case is strongest when the protocol can show three things at the same time:

1. Growing TVL.
2. Sustained swap volume.
3. Increasing share price over time.

When those three align, The Pool becomes a clean investor story: volume creates fees, fees improve LP economics, and vault shares make that value easy to hold.