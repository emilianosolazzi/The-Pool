# Deployed Addresses — The Pool

> Update this file whenever a production contract is broadcast. Treat it as the
> single source of truth for `web/`, `scripts/keeper/`, and Foundry scripts.

## Arbitrum One (chainid `42161`) — V2.1 (Phase C, broadcast Apr 2026)

| Component             | Address                                      |
|-----------------------|----------------------------------------------|
| FeeDistributor        | `0x5757DA9014EE91055b244322a207EE6F066378B0` |
| DynamicFeeHookV2      | `0x486579DE6391053Df88a073CeBd673dd545200cC` |
| SwapRouter02Adapter   | `0xdF9Ba20e7995A539Db9fB6DBCcbA3b54D026e393` |
| VaultMath (library)   | `0x94e8B53BB5a5d2aaa4C4d1e48639591346Fe7375` |
| VaultLP   (library)   | `0xC181cBFae6f1457fE7bb25dc9F0161E01A182A2a` |
| LiquidityVaultV2      | `0xf79c2dc829cd3a2d8ceec353bdb1b2414ba1eee0` |
| VaultOwnerController  | `0xa0e1580CAe87027D023E9dE94899346BFA383724` |
| VaultLens             | `0x12e86890b75fdee22a35be66550373936d883551` |
| BootstrapRewards      | `0x3E6Ed05c1140612310DDE0d0DDaAcCA6e0d7a03d` |

### Operations roles

| Role | Address / status |
|------|------------------|
| Reserve desk write target (`KEEPER_WRITE_TARGET`) | `0xa0e1580CAe87027D023E9dE94899346BFA383724` |
| Hot reserve keeper EOA (adjusts reserve offers) | `0x5cb4D906f0464B34C44d6555A770BF6af4a2CeFE` |
| Controller owner / Safe | `0x75062AF3303d80eE4Cd33602866bFA4f63b485f5` |
| Ledger / real treasury | `0xe5f5Ef79b3DFF47EcDf7842645222e43AD0ed080` |

The hot reserve keeper is allowlisted on the controller with
`reserveKeepers(0x5cb4D906f0464B34C44d6555A770BF6af4a2CeFE) == true` and
is the signer used by the automated reserve desk to post, rebalance, cancel,
and collect reserve offers. It cannot refresh NAV or run admin calls; those go
through the controller owner / Safe.

> BootstrapRewards wired Apr 28 2026 (block 457108969):
> `programStart = 1777348921`, `programEnd = 1792900921` (180 days, 6×30d epochs).
> `FeeDistributor.treasury = bootstrap`; `bootstrap.realTreasury = Ledger`.
> `LiquidityVaultV2.bootstrapRewards = bootstrap` (auto-poke on share moves).

### Pool & infrastructure (canonical, unchanged)

| Component             | Address                                      |
|-----------------------|----------------------------------------------|
| PoolManager (v4)      | `0x360e68faccca8ca495c1b759fd9eee466db9fb32` |
| PositionManager (v4)  | `0xd88f38f930b7952f2db2432cb002e7abbf3dd869` |
| Permit2               | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |
| WETH (token0)         | `0x82aF49447D8a07e3bd95BD0d56f35241523fBab1` |
| USDC native (token1)  | `0xaf88d065e77c8cC2239327C5EDb3A432268e5831` |
| Universal Router      | `0xa51afafe0263b40edaef0df8781ea9aa03e381a3` |
| V4Quoter              | `0x3972c00f7ed4885e145823eb7c655375d275a1c5` |

### Pool config

- Fee tier: `500`
- Tick spacing: `60`
- Active range: `[-199020, -198840]`
- `INIT_SQRT_PRICE_X96`: `3804161611805077128531558`

## Frontend env (Vercel — Production target)

```env
NEXT_PUBLIC_VAULT_ARB_ONE=0xf79c2dc829cd3a2d8ceec353bdb1b2414ba1eee0
NEXT_PUBLIC_VAULT_CONTROLLER_ARB_ONE=0xa0e1580CAe87027D023E9dE94899346BFA383724
NEXT_PUBLIC_VAULT_LENS_ARB_ONE=0x12e86890b75fdee22a35be66550373936d883551
NEXT_PUBLIC_HOOK_ARB_ONE=0x486579DE6391053Df88a073CeBd673dd545200cC
NEXT_PUBLIC_DISTRIBUTOR_ARB_ONE=0x5757DA9014EE91055b244322a207EE6F066378B0
NEXT_PUBLIC_BOOTSTRAP_ARB_ONE=0x3E6Ed05c1140612310DDE0d0DDaAcCA6e0d7a03d
NEXT_PUBLIC_POOL_MANAGER_ARB_ONE=0x360e68faccca8ca495c1b759fd9eee466db9fb32
NEXT_PUBLIC_ASSET_ARB_ONE=0xaf88d065e77c8cC2239327C5EDb3A432268e5831
NEXT_PUBLIC_ASSET_SYMBOL=USDC
NEXT_PUBLIC_ASSET_DECIMALS=6
NEXT_PUBLIC_PAIR_SYMBOL=WETH / USDC
NEXT_PUBLIC_DEFAULT_CHAIN_ID=42161
```

## Keeper env (`scripts/keeper`)

```env
VAULT=0xf79c2dc829cd3a2d8ceec353bdb1b2414ba1eee0
VAULT_LENS=0x12e86890b75fdee22a35be66550373936d883551
HOOK=0x486579DE6391053Df88a073CeBd673dd545200cC
KEEPER_WRITE_TARGET=0xa0e1580CAe87027D023E9dE94899346BFA383724
ARBITRUM_RPC_URL=https://arb1.arbitrum.io/rpc
KEEPER_PRIVATE_KEY=0x...   # required for writes; signer EOA should be 0x5cb4D906f0464B34C44d6555A770BF6af4a2CeFE or another allowlisted keeper
DRY_RUN=true               # simulate writes; flip to false only after first sanity tick
READ_ONLY=false            # true = real chain reads/metrics only, no private key or writes
METRICS_HOST=127.0.0.1     # Prometheus scrape bind address
METRICS_PORT=9464          # use 0 to disable /metrics
```

## History

- **V1 (deprecated):** vault `0x02D5a1340D378695D50FF7dE0F5778018952c5EA`, hook `0x453CFf45DAC5116f8D49f7cfE6AEB56107a780c4`, distributor `0x9e3aAb5DdBF536c087319431afCAf2F1160942e1`, bootstrap `0x029C2FEeB98050295C108E370fa74081ed58F978`. Do not point new clients at these.
