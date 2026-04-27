/**
 * Reserve-offer keeper for The Pool.
 *
 * Posts and rebalances VAULT_SPREAD reserve offers on
 * `LiquidityVaultV2` so the vault monetises spread vs. the AMM mid as
 * additional NAV. See `docs/HOOK-RISK-RUNBOOK.md` §3.4 for the policy.
 *
 * The keeper key must be the vault `owner()` — both
 * `offerReserveToHookWithMode` and `rebalanceOfferWithMode` are
 * `onlyOwner`.
 *
 * Required env:
 *   ARBITRUM_RPC_URL       JSON-RPC endpoint
 *   KEEPER_PRIVATE_KEY     0x-prefixed private key for the vault owner
 *   VAULT                  LiquidityVaultV2 address
 *   HOOK                   DynamicFeeHookV2 address
 *
 * Tunables (all optional):
 *   SPREAD_BPS                25       // vault premium vs AMM mid (bps)
 *   REBALANCE_DRIFT_BPS       50       // rebalance when |drift| >= this
 *   MAX_OFFER_BPS_OF_IDLE     500      // 5% of idle asset per offer
 *   OFFER_TTL_SECONDS         900      // 15 min expiry
 *   MIN_SELL_AMOUNT           1000000  // 1 USDC at 6 decimals
 *   GAS_SAFETY_MULTIPLIER     3        // require expectedSpread >= 3 * gasCost
 *   ASSET_PER_NATIVE_E18      0        // asset units per 1e18 wei native;
 *                                      // 0 disables the profitability guard
 *   DRY_RUN                   false    // simulate only, do not broadcast
 *   LOOP                      false    // run forever vs single tick
 *   INTERVAL_MS               60000    // base sleep between ticks
 *   JITTER_MS                 15000    // random extra sleep [0, JITTER_MS]
 */
import {
  createPublicClient,
  createWalletClient,
  http,
  parseAbi,
  type Address,
} from 'viem';
import { arbitrum } from 'viem/chains';
import { privateKeyToAccount } from 'viem/accounts';

const RPC_URL = mustEnv('ARBITRUM_RPC_URL');
const KEEPER_PRIVATE_KEY = mustEnv('KEEPER_PRIVATE_KEY') as `0x${string}`;

const VAULT = mustEnv('VAULT') as Address;
const HOOK = mustEnv('HOOK') as Address;

const DRY_RUN = process.env.DRY_RUN === 'true';

const SPREAD_BPS = BigInt(process.env.SPREAD_BPS ?? '25');
const REBALANCE_DRIFT_BPS = BigInt(process.env.REBALANCE_DRIFT_BPS ?? '50');
const MAX_OFFER_BPS_OF_IDLE = BigInt(process.env.MAX_OFFER_BPS_OF_IDLE ?? '500');
const OFFER_TTL_SECONDS = BigInt(process.env.OFFER_TTL_SECONDS ?? '900');
const MIN_SELL_AMOUNT = BigInt(process.env.MIN_SELL_AMOUNT ?? '1000000');

// Profitability guard. Skip a write if the *expected* spread profit on the
// offer (in `asset` units) is below `gasCost * GAS_SAFETY_MULTIPLIER`,
// where gasCost is priced in `asset` via ASSET_PER_NATIVE_E18 (asset units
// per 1e18 wei of native). On Arbitrum this is cheap, but the guard avoids
// dust rebalances. Set ASSET_PER_NATIVE_E18=0 to disable.
const GAS_SAFETY_MULTIPLIER = BigInt(process.env.GAS_SAFETY_MULTIPLIER ?? '3');
const ASSET_PER_NATIVE_E18 = BigInt(process.env.ASSET_PER_NATIVE_E18 ?? '0');

// Loop jitter. Each tick sleeps INTERVAL_MS + random([0, JITTER_MS]).
const INTERVAL_MS = Number(process.env.INTERVAL_MS ?? '60000');
const JITTER_MS = Number(process.env.JITTER_MS ?? '15000');

// ReservePricingMode enum (see src/DynamicFeeHookV2.sol):
//   0 = PRICE_IMPROVEMENT
//   1 = VAULT_SPREAD
const VAULT_SPREAD_MODE = 1 as const;

// LiquidityVaultV2.VaultStatus enum:
//   0 = UNCONFIGURED
//   1 = PAUSED
//   2 = IN_RANGE
//   3 = OUT_OF_RANGE
const VAULT_STATUS_PAUSED = 1;
const VAULT_STATUS_UNCONFIGURED = 0;

function mustEnv(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`Missing env ${name}`);
  return v;
}

const vaultAbi = parseAbi([
  'function poolKey() view returns (address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks)',
  'function asset() view returns (address)',
  'function owner() view returns (address)',
  'function vaultStatus() view returns (uint8)',
  'function offerReserveToHookWithMode(address sellCurrency,uint128 sellAmount,uint160 vaultSqrtPriceX96,uint64 expiry,uint8 mode)',
  'function rebalanceOfferWithMode(address sellCurrency,uint128 sellAmount,uint160 vaultSqrtPriceX96,uint64 expiry,uint8 mode)',
]);

const hookAbi = parseAbi([
  'function getOfferHealth((address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks) key,address vault) view returns (bool active,int256 driftBps,uint256 escrow0,uint256 escrow1,uint256 proceeds0,uint256 proceeds1,uint160 vaultSqrtPriceX96,uint160 poolSqrtPriceX96)',
  'function failedDistribution(address currency) view returns (uint256)',
]);

const erc20Abi = parseAbi([
  'function balanceOf(address) view returns (uint256)',
  'function decimals() view returns (uint8)',
]);

const account = privateKeyToAccount(KEEPER_PRIVATE_KEY);

const publicClient = createPublicClient({
  chain: arbitrum,
  transport: http(RPC_URL),
});

const walletClient = createWalletClient({
  account,
  chain: arbitrum,
  transport: http(RPC_URL),
});

function abs(x: bigint): bigint {
  return x < 0n ? -x : x;
}

function capOfferAmount(idleBalance: bigint): bigint {
  return (idleBalance * MAX_OFFER_BPS_OF_IDLE) / 10_000n;
}

// ---- Metrics --------------------------------------------------------------
const metrics = {
  startedAt: new Date().toISOString(),
  ticks: 0,
  posts: 0,
  rebalances: 0,
  noops: 0,
  errors: 0,
  gasSpentWei: 0n,
  spreadBpsLastFill: 0n,
};

function logMetrics() {
  console.log('[metrics]', {
    ...metrics,
    gasSpentWei: metrics.gasSpentWei.toString(),
    spreadBpsLastFill: metrics.spreadBpsLastFill.toString(),
  });
}

/// Approximate the spread the vault would earn on a single full-inventory
/// fill, expressed in `asset` units. For SPREAD_BPS << 10000 this is
/// roughly: sellAmount * SPREAD_BPS / 10000.
function expectedSpreadInAsset(sellAmount: bigint): bigint {
  return (sellAmount * SPREAD_BPS) / 10_000n;
}

/// Convert `gas * gasPriceWei` to `asset` units using ASSET_PER_NATIVE_E18.
/// Returns 0n when ASSET_PER_NATIVE_E18 is unset (guard disabled).
function gasCostInAsset(gas: bigint, gasPriceWei: bigint): bigint {
  if (ASSET_PER_NATIVE_E18 === 0n) return 0n;
  const wei = gas * gasPriceWei;
  return (wei * ASSET_PER_NATIVE_E18) / 10n ** 18n;
}

function sleep(ms: number): Promise<void> {
  return new Promise((res) => setTimeout(res, ms));
}

/**
 * VAULT_SPREAD math.
 *
 * sqrtP = sqrt(P). For small spread s, sqrtP' ≈ sqrtP * (1 ± s/2).
 *
 * Selling currency1 (e.g. USDC) — vault wants pool >= vault, so vault
 * sqrtP must be BELOW pool sqrtP. Use (1 - s/2).
 */
function vaultSpreadSqrtForSellingCurrency1(poolSqrtPriceX96: bigint, spreadBps: bigint): bigint {
  return (poolSqrtPriceX96 * (20_000n - spreadBps)) / 20_000n;
}

/**
 * Selling currency0 (e.g. WETH) — vault wants pool <= vault, so vault
 * sqrtP must be ABOVE pool sqrtP. Use (1 + s/2).
 */
function vaultSpreadSqrtForSellingCurrency0(poolSqrtPriceX96: bigint, spreadBps: bigint): bigint {
  return (poolSqrtPriceX96 * (20_000n + spreadBps)) / 20_000n;
}

async function sendOrPrint(
  label: string,
  functionName: 'offerReserveToHookWithMode' | 'rebalanceOfferWithMode',
  args: readonly [Address, bigint, bigint, bigint, number],
) {
  console.log(`\nAction: ${label}`);
  console.log({ functionName, args: args.map(String) });

  // Profitability guard.
  if (ASSET_PER_NATIVE_E18 > 0n && !DRY_RUN) {
    try {
      const [gas, gasPrice] = await Promise.all([
        publicClient.estimateContractGas({
          account,
          address: VAULT,
          abi: vaultAbi,
          functionName,
          args,
        }),
        publicClient.getGasPrice(),
      ]);
      const sellAmount = args[1];
      const expectedProfit = expectedSpreadInAsset(sellAmount);
      const gasCost = gasCostInAsset(gas, gasPrice);
      const required = gasCost * GAS_SAFETY_MULTIPLIER;
      console.log('[profit-guard]', {
        gas: gas.toString(),
        gasPriceWei: gasPrice.toString(),
        gasCostAsset: gasCost.toString(),
        expectedProfitAsset: expectedProfit.toString(),
        requiredAsset: required.toString(),
      });
      if (expectedProfit < required) {
        console.warn(
          `Skipping ${label}: expected profit ${expectedProfit} < required ${required}.`,
        );
        metrics.noops += 1;
        return;
      }
    } catch (err) {
      console.warn('Profitability guard failed; proceeding anyway:', err);
    }
  }

  if (DRY_RUN) {
    console.log('DRY_RUN=true, not sending tx.');
    return;
  }

  const { request } = await publicClient.simulateContract({
    account,
    address: VAULT,
    abi: vaultAbi,
    functionName,
    args,
  });

  const hash = await walletClient.writeContract(request);
  console.log(`Tx sent: ${hash}`);

  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  console.log(`Tx status: ${receipt.status}`);
  if (receipt.status === 'success') {
    metrics.gasSpentWei += BigInt(receipt.gasUsed) * BigInt(receipt.effectiveGasPrice ?? 0n);
    metrics.spreadBpsLastFill = SPREAD_BPS;
    if (functionName === 'offerReserveToHookWithMode') metrics.posts += 1;
    else metrics.rebalances += 1;
  } else {
    metrics.errors += 1;
  }
}

async function tick() {
  console.log(`\n[${new Date().toISOString()}] Keeper tick`);

  const [pkC0, pkC1, pkFee, pkSpacing, pkHooks] = await publicClient.readContract({
    address: VAULT,
    abi: vaultAbi,
    functionName: 'poolKey',
  });
  const poolKey = {
    currency0: pkC0,
    currency1: pkC1,
    fee: pkFee,
    tickSpacing: pkSpacing,
    hooks: pkHooks,
  } as const;

  const [asset, ownerAddr, vaultStatus] = await Promise.all([
    publicClient.readContract({ address: VAULT, abi: vaultAbi, functionName: 'asset' }),
    publicClient.readContract({ address: VAULT, abi: vaultAbi, functionName: 'owner' }),
    publicClient.readContract({ address: VAULT, abi: vaultAbi, functionName: 'vaultStatus' }),
  ]);

  if (ownerAddr.toLowerCase() !== account.address.toLowerCase()) {
    throw new Error(
      `Keeper key ${account.address} is not vault owner ${ownerAddr}. ` +
        `offerReserveToHookWithMode/rebalanceOfferWithMode are onlyOwner.`,
    );
  }

  if (vaultStatus === VAULT_STATUS_PAUSED) {
    console.log('Vault is PAUSED. Skipping.');
    return;
  }
  if (vaultStatus === VAULT_STATUS_UNCONFIGURED) {
    console.log('Vault is UNCONFIGURED. Skipping.');
    return;
  }

  const idleAsset = await publicClient.readContract({
    address: asset,
    abi: erc20Abi,
    functionName: 'balanceOf',
    args: [VAULT],
  });

  const health = await publicClient.readContract({
    address: HOOK,
    abi: hookAbi,
    functionName: 'getOfferHealth',
    args: [poolKey, VAULT],
  });

  const [
    active,
    driftBps,
    escrow0,
    escrow1,
    proceeds0,
    proceeds1,
    currentVaultSqrt,
    poolSqrt,
  ] = health;

  const failedAsset = await publicClient.readContract({
    address: HOOK,
    abi: hookAbi,
    functionName: 'failedDistribution',
    args: [asset],
  });

  console.log({
    keeper: account.address,
    asset,
    idleAsset: idleAsset.toString(),
    active,
    driftBps: driftBps.toString(),
    escrow0: escrow0.toString(),
    escrow1: escrow1.toString(),
    proceeds0: proceeds0.toString(),
    proceeds1: proceeds1.toString(),
    currentVaultSqrt: currentVaultSqrt.toString(),
    poolSqrt: poolSqrt.toString(),
    failedAsset: failedAsset.toString(),
    vaultStatus,
  });

  if (failedAsset > 0n) {
    console.warn(
      `ALERT: failedDistribution[${asset}] = ${failedAsset}. Owner must call ` +
        `acknowledgeFailedDistribution(...) on the hook after off-chain settlement.`,
    );
  }

  if (poolSqrt === 0n) {
    console.warn('Pool sqrt is zero; pool uninitialized. Skipping.');
    return;
  }

  if (idleAsset < MIN_SELL_AMOUNT) {
    console.log('Idle asset below minimum sell amount. Skipping.');
    return;
  }

  const sellAmount = capOfferAmount(idleAsset);

  if (sellAmount < MIN_SELL_AMOUNT) {
    console.log('Capped sell amount below minimum. Skipping.');
    return;
  }

  // Pick spread direction based on which side of the pool `asset` is on.
  const sellingCurrency1 = asset.toLowerCase() === poolKey.currency1.toLowerCase();
  const vaultSqrtPriceX96 = sellingCurrency1
    ? vaultSpreadSqrtForSellingCurrency1(poolSqrt, SPREAD_BPS)
    : vaultSpreadSqrtForSellingCurrency0(poolSqrt, SPREAD_BPS);

  const expiry = BigInt(Math.floor(Date.now() / 1000)) + OFFER_TTL_SECONDS;

  const args = [
    asset,
    sellAmount,
    vaultSqrtPriceX96,
    expiry,
    VAULT_SPREAD_MODE,
  ] as const;

  if (!active) {
    await sendOrPrint('post VAULT_SPREAD reserve offer', 'offerReserveToHookWithMode', args);
    return;
  }

  if (abs(driftBps) >= REBALANCE_DRIFT_BPS) {
    await sendOrPrint('rebalance stale VAULT_SPREAD reserve offer', 'rebalanceOfferWithMode', args);
    return;
  }

  metrics.noops += 1;
  console.log('Active offer healthy. No action.');
}

async function safeTick() {
  metrics.ticks += 1;
  try {
    await tick();
  } catch (err) {
    metrics.errors += 1;
    console.error('Keeper tick failed:', err);
  } finally {
    logMetrics();
  }
}

async function main() {
  await safeTick();

  if (process.env.LOOP !== 'true') return;

  // Loop with jittered interval. Avoids predictable, gameable timing.
  // eslint-disable-next-line no-constant-condition
  while (true) {
    const jitter = JITTER_MS > 0 ? Math.floor(Math.random() * JITTER_MS) : 0;
    await sleep(INTERVAL_MS + jitter);
    await safeTick();
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
