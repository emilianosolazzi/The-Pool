'use client';

/**
 * ProofStrip — six live on-chain numbers immediately under the hero so the
 * first thing a visitor sees after the pitch is the receipts:
 *
 *   TVL · Share price · Hook fees routed · Reserve fills · Bonus pool · Depositors
 *
 * All values come from VaultLens, DynamicFeeHookV2, and BootstrapRewards.
 * Refreshed every 20s. Falls back to "—" when the vault is not deployed on
 * the connected chain so the layout stays stable.
 */

import { useReadContract, useReadContracts } from 'wagmi';
import { vaultAbi, lensAbi, hookAbi, bootstrapAbi, erc20Abi } from '@/lib/abis';
import { fmtCompact, fmtUnits } from '@/lib/format';
import type { Deployment } from '@/lib/deployments';
import type { Address } from 'viem';

interface Props {
  deployment: Deployment;
  chainId: number;
}

export function ProofStrip({ deployment, chainId }: Props) {
  const vault = deployment.vault as Address | undefined;
  const lens = deployment.lens as Address | undefined;
  const hook = deployment.hook as Address | undefined;
  const bootstrap = deployment.bootstrap as Address | undefined;

  const { data: stats } = useReadContract({
    address: lens,
    abi: lensAbi,
    functionName: 'getVaultStats',
    args: vault ? [vault] : undefined,
    chainId,
    query: { enabled: Boolean(vault && lens), refetchInterval: 20_000 },
  });

  const { data: hookCounters } = useReadContracts({
    allowFailure: true,
    contracts: hook
      ? ([
          { address: hook, abi: hookAbi, functionName: 'totalFeesRouted', chainId },
          { address: hook, abi: hookAbi, functionName: 'totalReserveFills', chainId },
        ] as const)
      : [],
    query: { enabled: Boolean(hook), refetchInterval: 20_000 },
  });

  const { data: bootstrapEpoch0 } = useReadContract({
    address: bootstrap,
    abi: bootstrapAbi,
    functionName: 'epochs',
    args: [0n],
    chainId,
    query: { enabled: Boolean(bootstrap), refetchInterval: 30_000 },
  });

  const { data: payoutAsset } = useReadContract({
    address: bootstrap,
    abi: bootstrapAbi,
    functionName: 'payoutAsset',
    chainId,
    query: { enabled: Boolean(bootstrap), staleTime: 300_000 },
  });

  const { data: bootstrapBalance } = useReadContract({
    address: payoutAsset as Address | undefined,
    abi: erc20Abi,
    functionName: 'balanceOf',
    args: bootstrap ? [bootstrap] : undefined,
    chainId,
    query: { enabled: Boolean(bootstrap && payoutAsset), refetchInterval: 30_000 },
  });

  const tvl = stats && Array.isArray(stats) ? (stats[0] as bigint) : undefined;
  const sharePrice = stats && Array.isArray(stats) ? (stats[1] as bigint) : undefined;
  const depositors = stats && Array.isArray(stats) ? (stats[2] as bigint) : undefined;
  const feesRouted = hookCounters?.[0]?.status === 'success' ? (hookCounters[0].result as bigint) : undefined;
  const reserveFills = hookCounters?.[1]?.status === 'success' ? (hookCounters[1].result as bigint) : undefined;
  const bonusPool = bootstrapEpoch0 && Array.isArray(bootstrapEpoch0) ? (bootstrapEpoch0[0] as bigint) : undefined;
  const bonusActual = (bonusPool ?? 0n) > (bootstrapBalance ?? 0n) ? bonusPool : bootstrapBalance ?? bonusPool;

  const sym = deployment.assetSymbol;
  const dec = deployment.assetDecimals;

  const cells: { label: string; value: string; sub: string }[] = [
    {
      label: 'TVL',
      value: tvl !== undefined ? `${fmtCompact(tvl, dec)} ${sym}` : '—',
      sub: 'Live vault assets',
    },
    {
      label: 'Share price',
      value: sharePrice !== undefined ? fmtUnits(sharePrice, 18, 6) : '—',
      sub: '1 share → asset',
    },
    {
      label: 'Hook fees routed',
      value: feesRouted !== undefined ? `${fmtCompact(feesRouted, dec)} ${sym}` : '—',
      sub: 'Lifetime, on-chain',
    },
    {
      label: 'Reserve fills',
      value: reserveFills !== undefined ? reserveFills.toString() : '—',
      sub: 'Hook-settled trades',
    },
    {
      label: 'Bonus pool',
      value: bonusActual !== undefined ? `${fmtCompact(bonusActual, dec)} ${sym}` : '—',
      sub: 'Epoch 0, claimable',
    },
    {
      label: 'Depositors',
      value: depositors !== undefined ? depositors.toString() : '—',
      sub: 'Unique LPs',
    },
  ];

  return (
    <section
      aria-label="Live on-chain proof"
      className="border-b border-white/5 bg-black/30 backdrop-blur-sm"
    >
      <div className="mx-auto max-w-6xl px-4 py-6">
        <div className="mb-3 flex items-center gap-2 text-xs uppercase tracking-widest text-zinc-500">
          <span className="h-1.5 w-1.5 animate-pulse rounded-full bg-emerald-400" />
          Live on-chain · Arbitrum One
        </div>
        <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-6">
          {cells.map((c) => (
            <div
              key={c.label}
              className="rounded-xl border border-white/10 bg-white/[0.02] px-3 py-3"
            >
              <div className="text-[10px] uppercase tracking-wider text-zinc-500">
                {c.label}
              </div>
              <div className="mt-1 truncate font-mono text-base font-semibold text-white md:text-lg">
                {c.value}
              </div>
              <div className="mt-0.5 truncate text-[11px] text-zinc-500">{c.sub}</div>
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}
